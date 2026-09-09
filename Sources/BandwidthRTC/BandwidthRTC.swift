import AVFoundation
import Foundation
import WebRTC

/// Maximum number of reconnect attempts after an unexpected websocket close.
private let maxReconnectAttempts = 6

/// Upper bound on the exponential backoff between reconnect attempts, in seconds.
private let maxReconnectDelay: TimeInterval = 16

/// Fraction of the current backoff added as random jitter, to spread out clients that were all
/// disconnected by the same event.
private let jitterFraction: Double = 0.5

/// Handshake rejections that will recur on every retry, so reconnecting is pointless:
/// 403 (invalid token) and 409 (the gateway still has this endpoint marked connected).
private let fatalHandshakeStatusCodes: Set<Int> = [403, 409]

/// Main entry point for the Bandwidth BRTC SDK.
///
/// Usage:
/// ```swift
/// let brtc = BandwidthRTCClient()
/// brtc.onStreamAvailable = { stream in
///     // Handle remote audio streams
/// }
/// try await brtc.connect(authParams: .init(endpointToken: jwt))
/// let localStream = try await brtc.publish(audio: true)
/// ```
///
/// ```
public final class BandwidthRTCClient: @unchecked Sendable {

    // MARK: - Public Callbacks

    /// Called when a new remote stream becomes available.
    public var onStreamAvailable: (@Sendable (RtcStream) -> Void)?

    /// Called when a remote stream is removed.
    public var onStreamUnavailable: (@Sendable (String) -> Void)?

    /// Called when the BRTC platform signals readiness.
    public var onReady: (@Sendable (ReadyMetadata) -> Void)?

    /// Called when the remote side disconnects (subscribe ICE disconnected/failed).
    public var onRemoteDisconnected: (@Sendable () -> Void)?

    /// Called with Float32 audio samples for visualization after each mic capture or file chunk.
    /// Array contains 480+ samples (10ms+ at 48kHz).
    public var onLocalAudioLevel: (@Sendable ([Float32]) -> Void)?

    /// Called with Float32 audio samples for visualization after each remote audio playout chunk.
    /// Array contains 480+ samples (10ms+ at 48kHz).
    public var onRemoteAudioLevel: (@Sendable ([Float32]) -> Void)?

    /// Called when the SDK gives up on a session it cannot repair by itself - reconnect attempts
    /// exhausted or refused, or published streams that could not be restored after a reconnect.
    /// The session is unusable when this fires with `.reconnectFailed`; `isConnected` is false.
    public var onError: (@Sendable (Error) -> Void)?

    // MARK: - Internal Components

    var signaling: (any SignalingClientProtocol)?
    var peerConnectionManager: (any PeerConnectionManagerProtocol)?
    private var options: RtcOptions?
    private var authParams: RtcAuthParams?

    // Custom ADM — owns mic capture and remote audio playout
    public private(set) var mixingDevice: MixingAudioDevice?

    // MARK: - State

    private(set) public var isConnected = false
    /// True while an outbound or inbound call is active.
    /// Guards against processing stale SDP offers after hangup.
    private(set) var hasActiveCall = false

    /// Set by `disconnect()` so a socket close the application asked for never triggers a reconnect.
    private(set) var intentionalDisconnect = false

    /// Guards against overlapping reconnect loops while one is already running.
    private var reconnectTask: Task<Void, Never>?

    /// HTTP status of the most recent failed upgrade, when the gateway refused the handshake.
    private var lastCloseStatusCode: Int?

    /// First backoff delay, in seconds. Overridable so tests do not have to wait a real second.
    var reconnectBaseDelay: TimeInterval = 1

    // No pending SDP offers — both are answered during connect() init.

    // MARK: - Init

    public init(logLevel: LogLevel = .warn) {
        Logger.shared.level = logLevel
    }

    /// Internal init for testing — injects mock signaling, peer connection manager, and audio device.
    init(
        logLevel: LogLevel = .warn,
        signaling: (any SignalingClientProtocol)?,
        peerConnectionManager: (any PeerConnectionManagerProtocol)?,
        audioDevice: (any RTCAudioDevice)? = nil
    ) {
        Logger.shared.level = logLevel
        self.signaling = signaling
        self.peerConnectionManager = peerConnectionManager
        if let audioDevice = audioDevice {
            self.mixingDevice = audioDevice as? MixingAudioDevice
        }
    }

    // MARK: - Connection

    /// Connect to the BRTC platform using a JWT endpoint token.
    public func connect(authParams: RtcAuthParams, options: RtcOptions? = nil) async throws {
        guard !isConnected else { throw BandwidthRTCError.alreadyConnected }

        self.options = options
        self.authParams = authParams
        self.intentionalDisconnect = false
        self.lastCloseStatusCode = nil

        try await establishSession()
    }

    /// Open the websocket, (re)build the peer connections, and complete the initial SDP handshake.
    /// Used by both `connect()` and the reconnect loop.
    private func establishSession() async throws {
        guard let authParams else { throw BandwidthRTCError.notConnected }

        // Use injected signaling or create new
        let sig: any SignalingClientProtocol
        if let injected = self.signaling {
            sig = injected
        } else {
            let newSig = SignalingClient()
            self.signaling = newSig
            sig = newSig
        }

        // Register event handlers before connecting
        await registerEventHandlers(on: sig)

        // Connect WebSocket
        try await sig.connect(authParams: authParams, options: options)

        let pcMgr = try preparePeerConnectionManager()

        // Wire up peer connection callbacks
        pcMgr.onStreamAvailable = { [weak self] stream, mediaTypes, trackMetadata in
            let rtcStream = RtcStream(
                mediaStream: stream,
                mediaTypes: mediaTypes,
                from: trackMetadata?.from,
                fromType: trackMetadata?.fromType,
                autoAccepted: trackMetadata?.autoAccepted,
                tags: trackMetadata?.tags
            )
            // Always fire raw callback for backward compatibility
            self?.onStreamAvailable?(rtcStream)
        }
        pcMgr.onStreamUnavailable = { [weak self] streamId in
            self?.onStreamUnavailable?(streamId)
        }
        pcMgr.onSubscribingIceConnectionStateChange = { [weak self] state in
            Logger.shared.info("Subscribe ICE state changed: \(state.rawValue)")
            if state == .disconnected || state == .failed {
                Logger.shared.info("Subscribe ICE disconnected/failed — remote side likely hung up, clearing active call")
                self?.hasActiveCall = false
                self?.onRemoteDisconnected?()
            }
        }

        // Send setMediaPreferences to initiate the signaling flow.
        // The server responds with endpointId, deviceId, publishSdpOffer, and subscribeSdpOffer.
        let autoAccept = options?.autoAccept ?? true
        let mediaResult = try await sig.setMediaPreferences(autoAccept: autoAccept)
        Logger.shared.debug("setMediaPreferences result: endpoint=\(mediaResult.endpointId ?? "nil"), hasPublishOffer=\(mediaResult.publishSdpOffer != nil), hasSubscribeOffer=\(mediaResult.subscribeSdpOffer != nil), autoAccept=\(autoAccept)")

        // Answer BOTH initial SDP offers immediately (no tracks).
        // This establishes both peer connections, ICE, DTLS, and data channels right away.
        if let publishOffer = mediaResult.publishSdpOffer?.sdpOffer {
            Logger.shared.debug("Answering initial publish SDP offer (no tracks)...")
            let publishAnswer = try await pcMgr.answerInitialOffer(sdpOffer: publishOffer, pcType: .publish)
            try await sig.answerSdp(sdpAnswer: publishAnswer, peerType: "publish")
            Logger.shared.debug("Initial publish SDP answer sent")
        }

        if let subscribeOffer = mediaResult.subscribeSdpOffer?.sdpOffer {
            Logger.shared.debug("Answering initial subscribe SDP offer...")
            let subscribeAnswer = try await pcMgr.answerInitialOffer(sdpOffer: subscribeOffer, pcType: .subscribe)
            try await sig.answerSdp(sdpAnswer: subscribeAnswer, peerType: "subscribe")
            Logger.shared.debug("Initial subscribe SDP answer sent")
        }

        isConnected = true
        hasActiveCall = true
        Logger.shared.info("Connected to BRTC (endpoint=\(mediaResult.endpointId ?? "unknown"))")

        let readyMetadata = ReadyMetadata(
            endpointId: mediaResult.endpointId,
            deviceId: mediaResult.deviceId
        )
        onReady?(readyMetadata)
    }

    /// Reuse the existing peer connection manager (rebuilding its peer connections) or create one.
    /// Reusing keeps the factory, the audio device, and the retained published streams alive, and
    /// closing the dead peer connections before opening new ones is what stops repeated reconnects
    /// from leaking them.
    private func preparePeerConnectionManager() throws -> any PeerConnectionManagerProtocol {
        if let existing = peerConnectionManager {
            try existing.resetPeerConnections()
            return existing
        }

        // Create the custom ADM - it owns audio session config, mic capture, and playout
        let mixing = MixingAudioDevice(audioOptions: options?.audioProcessing ?? AudioProcessingOptions())
        mixing.onLocalAudioLevel = { [weak self] samples in self?.onLocalAudioLevel?(samples) }
        mixing.onRemoteAudioLevel = { [weak self] samples in self?.onRemoteAudioLevel?(samples) }
        self.mixingDevice = mixing

        // Set up peer connections with the custom ADM
        let newPCMgr = PeerConnectionManager(options: options, audioDevice: mixing)
        self.peerConnectionManager = newPCMgr
        try newPCMgr.setupPublishingPeerConnection()
        try newPCMgr.setupSubscribingPeerConnection()
        return newPCMgr
    }

    /// Disconnect from the BRTC platform.
    public func disconnect() async {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await self.cleanupSession()
        Logger.shared.info("Disconnected from BRTC")
    }

    // MARK: - Private: Session Cleanup

    private func cleanupSession() async {
        isConnected = false
        hasActiveCall = false
        peerConnectionManager?.cleanup()
        peerConnectionManager = nil
        _ = mixingDevice?.terminateDevice()
        mixingDevice = nil
        await signaling?.disconnect()
        signaling = nil
    }

    // MARK: - Private: Reconnect

    /// Decide what to do about a websocket that closed without the application asking.
    private func handleSocketClosed() {
        guard !intentionalDisconnect else {
            Logger.shared.debug("WebSocket closed after disconnect() - not reconnecting")
            return
        }
        if let code = lastCloseStatusCode, fatalHandshakeStatusCodes.contains(code) {
            Logger.shared.error("Gateway refused the connection (HTTP \(code)) - not reconnecting")
            failSession(BandwidthRTCError.reconnectFailed("gateway refused the connection (HTTP \(code))"))
            return
        }
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnect()
            self?.reconnectTask = nil
        }
    }

    /// Re-establish the session with bounded exponential backoff, then restore published streams.
    private func reconnect() async {
        var delay = reconnectBaseDelay
        var lastError: Error = BandwidthRTCError.webSocketDisconnected

        for attempt in 1...maxReconnectAttempts {
            // Jitter matters here specifically: a gateway drain evicts every idle endpoint on an
            // instance within the same sweep, so without it they all wake and retry in lockstep.
            let jittered = delay + Double.random(in: 0...(delay * jitterFraction))
            try? await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
            if intentionalDisconnect || Task.isCancelled { return }

            Logger.shared.info("Reconnect attempt \(attempt)/\(maxReconnectAttempts)")
            lastCloseStatusCode = nil
            do {
                try await establishSession()
            } catch {
                lastError = error
                Logger.shared.warn("Reconnect attempt \(attempt) failed: \(error)")
                if isFatalHandshakeError(error) {
                    Logger.shared.error("Gateway refused the connection - not retrying")
                    break
                }
                delay = min(delay * 2, maxReconnectDelay)
                continue
            }

            // The socket is back. Restore published streams once; a failure here leaves the
            // session up but not publishing, so it has to reach the application rather than
            // being retried into a 409 from the gateway.
            do {
                try await republishRetainedStreams()
                Logger.shared.info("Reconnected")
            } catch {
                Logger.shared.error("Failed to restore published streams after reconnect: \(error)")
                onError?(BandwidthRTCError.publishFailed(error.localizedDescription))
            }
            return
        }

        // Reached either by exhausting every attempt or by breaking out of the loop on a
        // refusal we will not retry, so report the reason rather than assuming exhaustion.
        Logger.shared.error("Giving up on reconnect: \(lastError)")
        await cleanupSession()
        onError?(BandwidthRTCError.reconnectFailed(lastError.localizedDescription))
    }

    /// Tear the session down and tell the application, for failures we will not retry.
    private func failSession(_ error: Error) {
        Task { [weak self] in
            await self?.cleanupSession()
            self?.onError?(error)
        }
    }

    /// Handshake rejections surfaced through the RPC layer rather than the upgrade response.
    private func isFatalHandshakeError(_ error: Error) -> Bool {
        if let code = lastCloseStatusCode, fatalHandshakeStatusCodes.contains(code) { return true }
        switch error {
        case BandwidthRTCError.invalidToken:
            return true
        case BandwidthRTCError.rpcError(let code, _):
            return fatalHandshakeStatusCodes.contains(code)
        default:
            return false
        }
    }

    /// Re-attach every retained published stream to the new publishing peer connection and
    /// renegotiate once for all of them. A no-op when nothing was ever published.
    private func republishRetainedStreams() async throws {
        guard let pcManager = peerConnectionManager, let signalingClient = signaling else {
            throw BandwidthRTCError.notConnected
        }

        try await pcManager.waitForPublishIceConnected()

        guard pcManager.reattachPublishedStreams() > 0 else {
            Logger.shared.debug("Nothing published - skipping republish")
            return
        }

        let localOffer = try await pcManager.createPublishOffer()
        let result = try await signalingClient.offerSdp(sdpOffer: localOffer, peerType: "publish")
        try await pcManager.applyPublishAnswer(localOffer: localOffer, remoteAnswer: result.sdpAnswer)
        Logger.shared.info("Republished retained streams")
    }

    // MARK: - Publishing

    /// Publish local audio.
    /// Adds local tracks, then creates a client-initiated offer sent via offerSdp.
    public func publish(audio: Bool = true, alias: String? = nil) async throws -> RtcStream {
        guard isConnected, let pcManager = peerConnectionManager, let signalingClient = signaling else {
            throw BandwidthRTCError.notConnected
        }

        // 1. Wait for the publish PC's initial ICE handshake to complete.
        //    The server rejects offerSdp with "peer not ready" if the initial
        //    handshake hasn't finished.
        Logger.shared.debug("Waiting for publish PC ICE to connect...")
        try await pcManager.waitForPublishIceConnected()
        Logger.shared.debug("Publish PC ICE connected — proceeding with publish")

        // 2. Add local audio track to the publishing peer connection
        let mediaStream = pcManager.addLocalTracks(audio: audio)

        // 3. Create a client-initiated offer with the newly added tracks
        let localOffer = try await pcManager.createPublishOffer()
        Logger.shared.debug("Created publish offer with local tracks")

        // 4. Send the offer to the server via offerSdp — server returns an SDP answer
        let result = try await signalingClient.offerSdp(sdpOffer: localOffer, peerType: "publish")
        Logger.shared.debug("Server answered publish offer")

        // 5. Apply the server's answer as remote description, and our offer as local description
        try await pcManager.applyPublishAnswer(localOffer: localOffer, remoteAnswer: result.sdpAnswer)
        Logger.shared.debug("Publish SDP exchange complete")

        var mediaTypes: [MediaType] = []
        if audio { mediaTypes.append(.audio) }

        let stream = RtcStream(mediaStream: mediaStream, mediaTypes: mediaTypes, alias: alias)
        Logger.shared.info("Published stream \(stream.streamId)")
        return stream
    }

    /// Unpublish a previously published stream.
    /// Removes the stream's tracks from the publish peer connection and renegotiates with the server.
    public func unpublish(stream: RtcStream) async throws {
        guard isConnected, let pcManager = peerConnectionManager, let signalingClient = signaling else {
            throw BandwidthRTCError.notConnected
        }

        // Remove the stream's tracks from the publish PC
        pcManager.removeLocalTracks(streamId: stream.streamId)

        // Renegotiate: create a new offer without the removed tracks
        let localOffer = try await pcManager.createPublishOffer()
        let result = try await signalingClient.offerSdp(sdpOffer: localOffer, peerType: "publish")
        try await pcManager.applyPublishAnswer(localOffer: localOffer, remoteAnswer: result.sdpAnswer)

        Logger.shared.info("Unpublished stream \(stream.streamId)")
    }

    // MARK: - Media Control

    /// Enable or disable the microphone for all published streams.
    public func setMicEnabled(_ enabled: Bool) {
        peerConnectionManager?.setAudioEnabled(enabled)
    }

    /// Send DTMF tones.
    /// - Parameters:
    ///   - tone: The DTMF tones to send — characters from `[0-9,*,#,A-D]`
    ///   - duration: Tone duration in milliseconds (default 100, range 70–6000)
    ///   - interToneGap: Gap between tones in milliseconds (default 70, minimum 50)
    public func sendDtmf(_ tone: String, duration: Int = 100, interToneGap: Int = 70) {
        peerConnectionManager?.sendDtmf(tone, duration: duration, interToneGap: interToneGap)
    }

    /// Get a snapshot of current call statistics.
    /// - Parameters:
    ///   - previousSnapshot: The previous snapshot for bitrate calculation (nil for first call)
    ///   - completion: Called with the stats snapshot on the main thread
    public func getCallStats(
        previousSnapshot: CallStatsSnapshot?,
        completion: @escaping (CallStatsSnapshot) -> Void
    ) {
        guard let pcManager = peerConnectionManager else {
            completion(CallStatsSnapshot())
            return
        }

        pcManager.getCallStats(
            previousInboundBytes: previousSnapshot?.bytesReceived ?? 0,
            previousOutboundBytes: previousSnapshot?.bytesSent ?? 0,
            previousTimestamp: previousSnapshot?.timestamp ?? 0,
            completion: completion
        )
    }

    // MARK: - Call Control (Low-Level)

    /// Request an outbound connection to a phone number, endpoint, or call ID.
    public func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        hasActiveCall = true
        return try await sig.requestOutboundConnection(id: id, type: type)
    }

    /// Hang up a connection.
    public func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        Logger.shared.info("hangupConnection called (endpoint=\(endpoint), type=\(type))")
        let result = try await sig.hangupConnection(endpoint: endpoint, type: type)
        Logger.shared.info("hangupConnection succeeded (result=\(result.result ?? "nil")) — clearing active call")
        hasActiveCall = false
        return result
    }

    /// Accept a parked inbound call, allowing audio to flow.
    /// Used when `autoAccept: false` is set in RtcOptions; the call remains ringing until accepted.
    public func acceptStream() async throws {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        Logger.shared.info("acceptStream called")
        try await sig.acceptStream()
        Logger.shared.debug("acceptStream succeeded")
    }

    /// Decline (reject) a parked inbound call.
    /// Used when `autoAccept: false` is set in RtcOptions; ends the ringing call.
    public func declineStream() async throws {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        Logger.shared.info("declineStream called")
        try await sig.declineStream()
        Logger.shared.debug("declineStream succeeded")
    }

    // MARK: - Configuration

    /// Set the SDK log level.
    public func setLogLevel(_ level: LogLevel) {
        Logger.shared.level = level
    }

    // MARK: - Private: Event Handlers

    private func registerEventHandlers(on signaling: any SignalingClientProtocol) async {
        // Handle incoming SDP offers for subscribing
        await signaling.onEvent("sdpOffer") { [weak self] data in
            guard let self else { return }
            Task {
                await self.handleSubscribeSdpOffer(data)
            }
        }

        // Handle ready event (may arrive after connect, e.g. for reconnection)
        await signaling.onEvent("ready") { [weak self] data in
            guard let self else { return }

            let metadata: ReadyMetadata
            if data.isEmpty {
                metadata = ReadyMetadata()
            } else {
                metadata = (try? JSONDecoder().decode(ReadyMetadata.self, from: data)) ?? ReadyMetadata()
            }

            Logger.shared.debug("Ready event: endpoint=\(metadata.endpointId ?? "nil")")
            self.onReady?(metadata)
        }

        // Handle established event
        await signaling.onEvent("established") { _ in
            Logger.shared.debug("Connection established")
        }

        // Handle disconnect
        await signaling.onEvent("close") { [weak self] data in
            guard let self else { return }
            let status = (try? JSONDecoder().decode(SocketCloseInfo.self, from: data))?.httpStatusCode
            Logger.shared.warn("WebSocket closed (status=\(status.map(String.init) ?? "none"))")
            self.isConnected = false
            self.hasActiveCall = false
            self.lastCloseStatusCode = status
            // The peer connections are dead but are kept (along with the audio device and the
            // retained published streams) until the next attempt resets them.
            self.handleSocketClosed()
        }
    }

    private func handleSubscribeSdpOffer(_ data: Data) async {
        Logger.shared.debug(">>> Subscribe SDP offer received (\(data.count) bytes)")

        guard hasActiveCall else {
            Logger.shared.info("Ignoring SDP offer — no active call (post-hangup)")
            return
        }

        guard let pcManager = peerConnectionManager, let sig = signaling else {
            Logger.shared.error("Subscribe SDP offer received but pcManager or signaling is nil")
            return
        }

        do {
            let notification: SDPOfferNotification
            do {
                notification = try JSONDecoder().decode(SDPOfferNotification.self, from: data)
            } catch {
                let rawPreview = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? "binary"
                Logger.shared.error("Failed to decode SDPOfferNotification: \(error)")
                Logger.shared.error("Raw data preview: \(rawPreview)")
                return
            }

            Logger.shared.debug("Subscribe SDP offer: revision=\(notification.sdpRevision.map(String.init) ?? "nil"), peerType=\(notification.peerType ?? "nil"), endpointId=\(notification.endpointId ?? "nil"), metadata keys=\(notification.trackMetadata?.keys.joined(separator: ",") ?? "none")")

            let answerSdp = try await pcManager.handleSubscribeSdpOffer(
                sdpOffer: notification.sdpOffer,
                sdpRevision: notification.sdpRevision,
                metadata: notification.trackMetadata
            )

            try await sig.answerSdp(sdpAnswer: answerSdp, peerType: "subscribe")

            Logger.shared.debug("<<< Subscribe SDP answer sent (revision=\(notification.sdpRevision.map(String.init) ?? "auto"))")
        } catch {
            Logger.shared.error("Failed to handle subscribe SDP offer: \(error)")
        }
    }
}
