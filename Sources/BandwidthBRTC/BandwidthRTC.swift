import AVFoundation
import Foundation
import WebRTC

/// Main entry point for the Bandwidth BRTC SDK.
///
/// Usage:
/// ```swift
/// let brtc = BandwidthRTC()
/// brtc.onStreamAvailable = { stream in
///     // Handle remote audio streams
/// }
/// try await brtc.connect(authParams: .init(endpointToken: jwt))
/// let localStream = try await brtc.publish(audio: true)
/// ```
public final class BandwidthRTC: @unchecked Sendable {

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

    // MARK: - Internal Components

    var signaling: (any SignalingClientProtocol)?
    var peerConnectionManager: (any PeerConnectionManagerProtocol)?
    private var options: RtcOptions?

    // Custom ADM — owns mic capture, file playback, and remote audio playout
    private var mixingDevice: MixingAudioDevice?

    // MARK: - State

    private(set) public var isConnected = false
    public private(set) var isPlayingFileAudio: Bool = false

    // No pending SDP offers — both are answered during connect() init, matching JS SDK.

    // MARK: - Init

    public init(logLevel: LogLevel = .warn) {
        Logger.shared.level = logLevel
    }

    /// Internal init for testing — injects mock signaling and peer connection manager.
    init(
        logLevel: LogLevel = .warn,
        signaling: (any SignalingClientProtocol)?,
        peerConnectionManager: (any PeerConnectionManagerProtocol)?
    ) {
        Logger.shared.level = logLevel
        self.signaling = signaling
        self.peerConnectionManager = peerConnectionManager
    }

    // MARK: - Connection

    /// Connect to the BRTC platform using a JWT endpoint token.
    public func connect(authParams: RtcAuthParams, options: RtcOptions? = nil) async throws {
        guard !isConnected else { throw BandwidthRTCError.alreadyConnected }

        // Clean up any stale state from a previous session that dropped without a clean disconnect
        if peerConnectionManager != nil || signaling != nil {
            Logger.shared.warn("connect() called with stale state — cleaning up previous session")
            peerConnectionManager?.cleanup()
            peerConnectionManager = nil
            _ = mixingDevice?.terminateDevice()
            mixingDevice = nil
            let staleSig = signaling
            signaling = nil
            await staleSig?.disconnect()
        }

        self.options = options

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

        // Use injected peer connection manager or create new
        let pcMgr: any PeerConnectionManagerProtocol
        if let injected = self.peerConnectionManager {
            pcMgr = injected
        } else {
            // Create the custom ADM — it owns audio session config, mic capture, and playout
            let mixing = MixingAudioDevice()
            mixing.onLocalAudioLevel = { [weak self] samples in self?.onLocalAudioLevel?(samples) }
            mixing.onRemoteAudioLevel = { [weak self] samples in self?.onRemoteAudioLevel?(samples) }
            self.mixingDevice = mixing

            // Set up peer connections with the custom ADM
            let newPCMgr = PeerConnectionManager(options: options, audioDevice: mixing)
            self.peerConnectionManager = newPCMgr
            newPCMgr.setupPublishingPeerConnection()
            newPCMgr.setupSubscribingPeerConnection()
            pcMgr = newPCMgr
        }

        // Wire up peer connection callbacks
        pcMgr.onStreamAvailable = { [weak self] stream, mediaTypes in
            let rtcStream = RtcStream(mediaStream: stream, mediaTypes: mediaTypes)
            self?.onStreamAvailable?(rtcStream)
        }
        pcMgr.onStreamUnavailable = { [weak self] streamId in
            self?.onStreamUnavailable?(streamId)
        }
        pcMgr.onSubscribingIceConnectionStateChange = { [weak self] state in
            if state == .disconnected || state == .failed {
                Logger.shared.info("Subscribe ICE disconnected/failed — remote side likely hung up")
                self?.onRemoteDisconnected?()
            }
        }

        // Send setMediaPreferences to initiate the signaling flow.
        // The server responds with endpointId, deviceId, publishSdpOffer, and subscribeSdpOffer.
        let mediaResult = try await sig.setMediaPreferences()
        Logger.shared.info("setMediaPreferences result: endpoint=\(mediaResult.endpointId ?? "nil"), hasPublishOffer=\(mediaResult.publishSdpOffer != nil), hasSubscribeOffer=\(mediaResult.subscribeSdpOffer != nil)")

        // Answer BOTH initial SDP offers immediately (no tracks) — matches JS SDK init() behavior.
        // This establishes both peer connections, ICE, DTLS, and data channels right away.
        if let publishOffer = mediaResult.publishSdpOffer?.sdpOffer {
            Logger.shared.info("Answering initial publish SDP offer (no tracks)...")
            let publishAnswer = try await pcMgr.answerInitialOffer(sdpOffer: publishOffer, pcType: .publish)
            try await sig.answerSdp(sdpAnswer: publishAnswer, peerType: "publish")
            Logger.shared.info("Initial publish SDP answer sent")
        }

        if let subscribeOffer = mediaResult.subscribeSdpOffer?.sdpOffer {
            Logger.shared.info("Answering initial subscribe SDP offer...")
            let subscribeAnswer = try await pcMgr.answerInitialOffer(sdpOffer: subscribeOffer, pcType: .subscribe)
            try await sig.answerSdp(sdpAnswer: subscribeAnswer, peerType: "subscribe")
            Logger.shared.info("Initial subscribe SDP answer sent")
        }

        isConnected = true
        Logger.shared.info("Connected to BRTC (endpoint=\(mediaResult.endpointId ?? "unknown"))")

        let readyMetadata = ReadyMetadata(
            endpointId: mediaResult.endpointId,
            deviceId: mediaResult.deviceId
        )
        onReady?(readyMetadata)
    }

    /// Disconnect from the BRTC platform.
    public func disconnect() {
        stopFileAudio()
        isConnected = false
        peerConnectionManager?.cleanup()
        peerConnectionManager = nil
        _ = mixingDevice?.terminateDevice()
        mixingDevice = nil

        // Capture before nil so the Task doesn't call disconnect() on nil
        let sig = signaling
        signaling = nil
        Task {
            await sig?.disconnect()
        }

        Logger.shared.info("Disconnected from BRTC")
    }

    // MARK: - Publishing

    /// Publish local audio.
    /// Matches JS SDK: adds tracks, then creates a client-initiated offer sent via offerSdp.
    public func publish(audio: Bool = true, alias: String? = nil) async throws -> RtcStream {
        guard isConnected, let pcManager = peerConnectionManager, let signalingClient = signaling else {
            throw BandwidthRTCError.notConnected
        }

        // 1. Wait for the publish PC's initial ICE handshake to complete.
        //    The server rejects offerSdp with "peer not ready" if the initial
        //    handshake hasn't finished. In the JS SDK there's a natural delay
        //    between init() and publish() (user interaction); we replicate that here.
        Logger.shared.info("Waiting for publish PC ICE to connect...")
        await pcManager.waitForPublishIceConnected()
        Logger.shared.info("Publish PC ICE connected — proceeding with publish")

        // 2. Add local audio track to the publishing peer connection
        let mediaStream = pcManager.addLocalTracks(audio: audio)

        // 3. Create a client-initiated offer with the newly added tracks
        let localOffer = try await pcManager.createPublishOffer()
        Logger.shared.info("Created publish offer with local tracks")

        // 4. Send the offer to the server via offerSdp — server returns an SDP answer
        let result = try await signalingClient.offerSdp(sdpOffer: localOffer, peerType: "publish")
        Logger.shared.info("Server answered publish offer")

        // 5. Apply the server's answer as remote description, and our offer as local description
        try await pcManager.applyPublishAnswer(localOffer: localOffer, remoteAnswer: result.sdpAnswer)
        Logger.shared.info("Publish SDP exchange complete")

        var mediaTypes: [MediaType] = []
        if audio { mediaTypes.append(.audio) }

        let stream = RtcStream(mediaStream: mediaStream, mediaTypes: mediaTypes, alias: alias)
        Logger.shared.info("Published stream \(stream.streamId)")
        return stream
    }

    /// Unpublish previously published streams.
    public func unpublish() async throws {
        // For now, cleanup is handled via disconnect
        // A full implementation would remove specific tracks and renegotiate
        Logger.shared.info("Unpublish called")
    }

    /// Swap the publish stream's audio source to the given file.
    /// The file is injected into the existing publish peer connection via `MixingAudioDevice`.
    public func publishFileAudio(url: URL) async throws {
        guard isConnected else {
            throw BandwidthRTCError.notConnected
        }

        guard let mixing = mixingDevice else {
            throw BandwidthRTCError.notConnected
        }

        // Stop any previously playing file audio before starting new
        stopFileAudio()

        try mixing.loadFile(url: url)
        mixing.startFilePlayback()
        isPlayingFileAudio = true
        Logger.shared.info("File audio started: \(url.lastPathComponent)")
    }

    /// Restore microphone as the audio source for the publish stream.
    public func stopFileAudio() {
        mixingDevice?.stopFilePlayback()
        isPlayingFileAudio = false
        Logger.shared.info("File audio stopped")
    }

    // MARK: - Media Control

    /// Enable or disable the microphone for all published streams.
    public func setMicEnabled(_ enabled: Bool) {
        peerConnectionManager?.setAudioEnabled(enabled)
    }

    /// Send DTMF tones.
    public func sendDtmf(_ tone: String) {
        peerConnectionManager?.sendDtmf(tone)
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

    // MARK: - Call Control

    /// Request an outbound connection to a phone number, endpoint, or call ID.
    public func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        return try await sig.requestOutboundConnection(id: id, type: type)
    }

    /// Hang up a connection.
    public func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        return try await sig.hangupConnection(endpoint: endpoint, type: type)
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

            Logger.shared.info("Ready event: endpoint=\(metadata.endpointId ?? "nil")")
            self.onReady?(metadata)
        }

        // Handle established event
        await signaling.onEvent("established") { _ in
            Logger.shared.info("Connection established")
        }

        // Handle disconnect
        await signaling.onEvent("close") { [weak self] _ in
            Logger.shared.warn("WebSocket closed")
            self?.isConnected = false
        }
    }

    private func handleSubscribeSdpOffer(_ data: Data) async {
        Logger.shared.info(">>> Subscribe SDP offer received (\(data.count) bytes)")

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

            Logger.shared.info("Subscribe SDP offer: revision=\(notification.sdpRevision.map(String.init) ?? "nil"), peerType=\(notification.peerType ?? "nil"), endpointId=\(notification.endpointId ?? "nil"), metadata keys=\(notification.streamSourceMetadata?.keys.joined(separator: ",") ?? "none")")

            let answerSdp = try await pcManager.handleSubscribeSdpOffer(
                sdpOffer: notification.sdpOffer,
                sdpRevision: notification.sdpRevision,
                metadata: notification.streamSourceMetadata
            )

            try await sig.answerSdp(sdpAnswer: answerSdp, peerType: "subscribe")

            Logger.shared.info("<<< Subscribe SDP answer sent (revision=\(notification.sdpRevision.map(String.init) ?? "auto"))")
        } catch {
            Logger.shared.error("Failed to handle subscribe SDP offer: \(error)")
        }
    }
}
