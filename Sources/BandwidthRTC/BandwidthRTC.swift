import AVFoundation
import CallKit
import Foundation
import WebRTC

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
/// For native CallKit integration, set `callDelegate`:
/// ```swift
/// let brtc = BandwidthRTCClient()
/// brtc.callDelegate = self  // conforms to BandwidthRTCCallDelegate
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

    // MARK: - CallKit Integration

    /// Delegate for receiving high-level call lifecycle events.
    /// Setting this enables CallKit integration automatically.
    public weak var callDelegate: (any BandwidthRTCCallDelegate)?

    /// Whether CallKit is enabled. Defaults to `true`.
    /// Set to `false` to disable CallKit even when a delegate is set (useful for testing).
    public var callKitEnabled: Bool = true

    /// The current call state. Only meaningful when `callDelegate` is set.
    public private(set) var callState: CallState = .idle

    /// Metadata about the current call. Nil when `callState` is `.idle`.
    public private(set) var currentCallInfo: CallInfo?

    // MARK: - Internal Components

    var signaling: (any SignalingClientProtocol)?
    var peerConnectionManager: (any PeerConnectionManagerProtocol)?
    private var options: RtcOptions?

    // Custom ADM — owns mic capture, file playback, and remote audio playout
    private var mixingDevice: MixingAudioDevice?

    // CallKit manager (lazily created when callDelegate is set)
    private var callKitManager: CallKitManager?

    // Stream held until user answers an incoming call via CallKit
    private var pendingIncomingStream: RtcStream?

    // MARK: - State

    private(set) public var isConnected = false
    public private(set) var isPlayingFileAudio: Bool = false

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
            // Reusing injected peer connection manager (for testing)
            pcMgr = injected
        } else {
            // Clean up any stale state from a previous session that dropped without a clean disconnect
            // This only applies when creating a new manager, not when reusing an injected one
            if peerConnectionManager != nil {
                Logger.shared.warn("connect() called with stale state — cleaning up previous session")
                await cleanupSession()
            }

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

        // Initialize CallKit manager if delegate is set
        if callDelegate != nil && callKitEnabled && callKitManager == nil {
            let ckManager = CallKitManager()
            ckManager.onUserAnswered = { [weak self] uuid in
                Task { @MainActor in
                    try? await self?.answerCall()
                }
            }
            ckManager.onUserEnded = { [weak self] uuid in
                Task { @MainActor in
                    if self?.callState == .ringing {
                        await self?.rejectCall()
                    } else {
                        try? await self?.endCall()
                    }
                }
            }
            callKitManager = ckManager
        }

        // Wire up peer connection callbacks
        pcMgr.onStreamAvailable = { [weak self] stream, mediaTypes in
            let rtcStream = RtcStream(mediaStream: stream, mediaTypes: mediaTypes)
            // Always fire raw callback for backward compatibility
            self?.onStreamAvailable?(rtcStream)
            // If CallKit integration is active, manage call state
            if let self, self.callDelegate != nil {
                Task { @MainActor in
                    self.handleStreamAvailableForCallKit(rtcStream)
                }
            }
        }
        pcMgr.onStreamUnavailable = { [weak self] streamId in
            self?.onStreamUnavailable?(streamId)
            if let self, self.callDelegate != nil {
                Task { @MainActor in
                    self.handleStreamUnavailableForCallKit(streamId)
                }
            }
        }
        pcMgr.onSubscribingIceConnectionStateChange = { [weak self] state in
            if state == .disconnected || state == .failed {
                Logger.shared.info("Subscribe ICE disconnected/failed — remote side likely hung up")
                self?.onRemoteDisconnected?()
                if let self, self.callDelegate != nil {
                    Task { @MainActor in
                        self.handleRemoteDisconnectedForCallKit()
                    }
                }
            }
        }

        // Send setMediaPreferences to initiate the signaling flow.
        // The server responds with endpointId, deviceId, publishSdpOffer, and subscribeSdpOffer.
        let mediaResult = try await sig.setMediaPreferences()
        Logger.shared.debug("setMediaPreferences result: endpoint=\(mediaResult.endpointId ?? "nil"), hasPublishOffer=\(mediaResult.publishSdpOffer != nil), hasSubscribeOffer=\(mediaResult.subscribeSdpOffer != nil)")

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
        Logger.shared.info("Connected to BRTC (endpoint=\(mediaResult.endpointId ?? "unknown"))")

        let readyMetadata = ReadyMetadata(
            endpointId: mediaResult.endpointId,
            deviceId: mediaResult.deviceId
        )
        onReady?(readyMetadata)
    }

    /// Disconnect from the BRTC platform.
    public func disconnect() async {
        stopFileAudio()
        // End any active call through CallKit before tearing down the session
        if callState != .idle {
            callKitManager?.reportCallEnded(reason: .remoteEnded)
            callKitManager?.deactivateAudioSessionForOutboundCall()
            await MainActor.run { transitionToIdle() }
        }
        isConnected = false
        callKitManager = nil
        await self.cleanupSession()
        Logger.shared.info("Disconnected from BRTC")
    }

    // MARK: - Private: Session Cleanup

    private func cleanupSession() async {
        peerConnectionManager?.cleanup()
        peerConnectionManager = nil
        _ = mixingDevice?.terminateDevice()
        mixingDevice = nil
        await signaling?.disconnect()
        signaling = nil
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
        await pcManager.waitForPublishIceConnected()
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

    // MARK: - Call Control (Low-Level)

    /// Request an outbound connection to a phone number, endpoint, or call ID.
    public func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }

        // If CallKit integration is active, track this as an outbound call
        if callDelegate != nil {
            let info = CallInfo(direction: .outbound, remoteParty: id)
            currentCallInfo = info
            callState = .connecting
            callKitManager?.activateAudioSessionForOutboundCall()
            await MainActor.run { notifyCallStateChange(.connecting) }
        }

        return try await sig.requestOutboundConnection(id: id, type: type)
    }

    /// Hang up a connection.
    public func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult {
        guard let sig = signaling, isConnected else { throw BandwidthRTCError.notConnected }
        return try await sig.hangupConnection(endpoint: endpoint, type: type)
    }

    // MARK: - Call Control (High-Level / CallKit)

    /// Answer an incoming call that was reported via the delegate.
    ///
    /// Unmutes the pending stream and transitions to `.active`.
    @MainActor
    public func answerCall() async throws {
        guard callState == .ringing else {
            throw BandwidthRTCError.noActiveCall
        }

        callState = .connecting
        notifyCallStateChange(.connecting)

        // Enable audio on the held stream
        if let stream = pendingIncomingStream {
            stream.mediaStream.audioTracks.forEach { $0.isEnabled = true }
            pendingIncomingStream = nil
            // Stream already available — go active immediately
            callState = .active
            callKitManager?.activateAudioSessionForOutboundCall()
            notifyCallStateChange(.active)
        }
        // If stream hasn't arrived yet, handleStreamAvailableForCallKit will
        // transition to .active when it does.
    }

    /// Reject an incoming call.
    @MainActor
    public func rejectCall() async {
        guard callState == .ringing else { return }
        callKitManager?.reportCallEnded(reason: .declinedElsewhere)
        pendingIncomingStream?.mediaStream.audioTracks.forEach { $0.isEnabled = false }
        pendingIncomingStream = nil
        transitionToIdle()
    }

    /// End the current active or connecting call.
    @MainActor
    public func endCall() async throws {
        guard callState == .active || callState == .connecting else { return }

        callKitManager?.reportCallEnded(reason: .remoteEnded)
        callKitManager?.deactivateAudioSessionForOutboundCall()

        // Hang up on the signaling layer if we know the remote party
        if let info = currentCallInfo, let remoteParty = info.remoteParty, let sig = signaling {
            _ = try? await sig.hangupConnection(endpoint: remoteParty, type: .phoneNumber)
        }

        transitionToIdle()
    }

    /// Report an incoming call to CallKit from an external trigger (e.g. PushKit).
    ///
    /// Use this when your app receives a VoIP push notification before the
    /// WebSocket stream arrives. The SDK will show the native call UI and wait
    /// for the stream to arrive.
    @MainActor
    public func reportIncomingCall(callerName: String, completion: ((Error?) -> Void)? = nil) {
        let info = CallInfo(direction: .inbound, remoteParty: callerName)
        currentCallInfo = info
        callState = .ringing

        callKitManager?.reportIncomingCall(callerName: callerName) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.callDelegate?.bandwidthRTC(self!, callDidFailWithError: error, info: info)
                    self?.transitionToIdle()
                }
            }
            completion?(error)
        }

        callDelegate?.bandwidthRTC(self, didReceiveIncomingCall: info)
        notifyCallStateChange(.ringing)
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
        await signaling.onEvent("close") { [weak self] _ in
            Logger.shared.warn("WebSocket closed")
            self?.isConnected = false
        }
    }

    // MARK: - Private: CallKit State Handlers

    @MainActor
    private func handleStreamAvailableForCallKit(_ stream: RtcStream) {
        switch callState {
        case .idle:
            // Unexpected stream while idle = incoming call
            pendingIncomingStream = stream
            stream.mediaStream.audioTracks.forEach { $0.isEnabled = false }

            let info = CallInfo(direction: .inbound, remoteParty: stream.alias)
            currentCallInfo = info
            callState = .ringing

            callKitManager?.reportIncomingCall(callerName: stream.alias ?? "Incoming Call") { [weak self] error in
                if let error, let self {
                    Task { @MainActor in
                        self.callDelegate?.bandwidthRTC(self, callDidFailWithError: error, info: info)
                    }
                }
            }

            callDelegate?.bandwidthRTC(self, didReceiveIncomingCall: info)
            notifyCallStateChange(.ringing)

        case .ringing:
            // Stream arrived while ringing — hold it until user answers
            pendingIncomingStream = stream
            stream.mediaStream.audioTracks.forEach { $0.isEnabled = false }

        case .connecting:
            // Stream arrived after user answered or during outbound call — go active
            callState = .active
            notifyCallStateChange(.active)

        case .active, .ended:
            break
        }
    }

    @MainActor
    private func handleStreamUnavailableForCallKit(_ streamId: String) {
        if callState == .active {
            callKitManager?.reportCallEnded(reason: .remoteEnded)
            callKitManager?.deactivateAudioSessionForOutboundCall()
            transitionToIdle()
        }
    }

    @MainActor
    private func handleRemoteDisconnectedForCallKit() {
        switch callState {
        case .ringing:
            callKitManager?.reportCallEnded(reason: .remoteEnded)
            pendingIncomingStream = nil
            transitionToIdle()
        case .connecting, .active:
            callKitManager?.reportCallEnded(reason: .remoteEnded)
            callKitManager?.deactivateAudioSessionForOutboundCall()
            transitionToIdle()
        case .idle, .ended:
            break
        }
    }

    @MainActor
    private func transitionToIdle() {
        let oldInfo = currentCallInfo
        let oldState = callState
        callState = .idle
        currentCallInfo = nil
        pendingIncomingStream = nil
        if oldState != .idle, let info = oldInfo {
            callDelegate?.bandwidthRTC(self, callDidChangeState: .ended, info: info)
        }
    }

    @MainActor
    private func notifyCallStateChange(_ state: CallState) {
        guard let info = currentCallInfo else { return }
        callDelegate?.bandwidthRTC(self, callDidChangeState: state, info: info)
    }

    private func handleSubscribeSdpOffer(_ data: Data) async {
        Logger.shared.debug(">>> Subscribe SDP offer received (\(data.count) bytes)")

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

            Logger.shared.debug("Subscribe SDP offer: revision=\(notification.sdpRevision.map(String.init) ?? "nil"), peerType=\(notification.peerType ?? "nil"), endpointId=\(notification.endpointId ?? "nil"), metadata keys=\(notification.streamSourceMetadata?.keys.joined(separator: ",") ?? "none")")

            let answerSdp = try await pcManager.handleSubscribeSdpOffer(
                sdpOffer: notification.sdpOffer,
                sdpRevision: notification.sdpRevision,
                metadata: notification.streamSourceMetadata
            )

            try await sig.answerSdp(sdpAnswer: answerSdp, peerType: "subscribe")

            Logger.shared.debug("<<< Subscribe SDP answer sent (revision=\(notification.sdpRevision.map(String.init) ?? "auto"))")
        } catch {
            Logger.shared.error("Failed to handle subscribe SDP offer: \(error)")
        }
    }
}
