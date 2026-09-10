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

/// Classify a rejected-handshake HTTP status into the error it represents. 403 (invalid token)
/// and 409 (the gateway still has this endpoint marked connected) will recur on every retry, so
/// reconnecting into either is pointless - nil for any other status, including none at all.
private func classifyFatalHandshake(_ statusCode: Int?) -> BandwidthRTCError? {
    switch statusCode {
    case 403: return .invalidToken
    case 409: return .endpointOccupied
    default: return nil
    }
}

/// Owns the reconnect loop's lifecycle: whether one is running, whether the application asked
/// to disconnect, and the last close's HTTP status. Guarded by a lock rather than left as plain
/// vars on `BandwidthRTCClient` because this is the one state that is genuinely touched from
/// two different, uncoordinated contexts - the WebSocket "close" event, which runs on whatever
/// executor `SignalingClient`'s receive loop happens to be suspended on, and the application's
/// `connect()`/`disconnect()` calls, which run on whatever the application calls them from.
/// `@unchecked Sendable` on the outer class means the compiler will not catch a race here on
/// its own.
private final class ReconnectState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var intentional = false
    private var lastCloseStatusCode: Int?
    /// Set when the socket drops again while an attempt is already in flight, so that attempt
    /// notices - right before it would otherwise report success - that the session it just
    /// re-established is already gone, instead of silently treating a dead session as healthy.
    private var againRequested = false
    /// Bumped on every `beginIfIdle` that actually starts a task, so a `finish()` from a task
    /// that raced its own spawning thread and completed before `stop()` + a fresh `beginIfIdle`
    /// reassigned `task` cannot nil out that newer task instead of its own, now-stale, slot.
    private var generation = 0

    func setIntentional(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        intentional = value
    }

    func isIntentional() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intentional
    }

    func setLastCloseStatusCode(_ code: Int?) {
        lock.lock(); defer { lock.unlock() }
        lastCloseStatusCode = code
    }

    func getLastCloseStatusCode() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return lastCloseStatusCode
    }

    /// Called from the close handler. Starts `work` as the reconnect loop unless one is
    /// already running, in which case this close is folded into it via `againRequested`
    /// instead of racing a second, competing attempt against the first.
    func beginIfIdle(_ work: @escaping () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !intentional else { return }
        guard task == nil else {
            againRequested = true
            return
        }
        // Task {} only schedules the closure onto the cooperative pool - it never runs
        // inline - so creating and assigning `task` while still holding the lock cannot
        // deadlock against `finish()`, which will simply block until this unlocks.
        generation &+= 1
        let gen = generation
        task = Task { [weak self] in
            await work()
            self?.finish(gen)
        }
    }

    /// Checked by the loop right before it would report success, and at the start of each
    /// attempt so a close from an earlier, already-retried attempt cannot masquerade as one
    /// that happened after the current attempt's success. Consumes the flag either way.
    func consumeAgainRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { againRequested = false }
        return againRequested
    }

    private func finish(_ gen: Int) {
        lock.lock(); defer { lock.unlock() }
        guard gen == generation else { return }
        task = nil
    }

    /// Cancel any running reconnect loop and wait for it to fully stop before returning. Task
    /// cancellation is cooperative - `establishSession()`'s awaits do not observe it on their
    /// own - so merely requesting cancellation is not enough; the caller needs the old loop
    /// provably gone before it can safely take over the session itself.
    func stop() async {
        lock.lock()
        let current = task
        task = nil
        lock.unlock()
        guard let current else { return }
        current.cancel()
        await current.value
    }
}

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

    /// Called when the session needs the application's attention because the SDK could not
    /// repair it by itself. A WebSocket close from anything other than `disconnect()` is not
    /// reported here on its own - the SDK reconnects with backoff and restores published
    /// streams first. This fires only for the outcomes that reconnect cannot paper over:
    /// - `.invalidToken` (HTTP 403) or `.endpointOccupied` (HTTP 409): the gateway refused the
    ///   handshake for a reason that will keep recurring, so no attempt was retried.
    ///   `isConnected` is false.
    /// - `.reconnectFailed`: every retry attempt failed. `isConnected` is false.
    /// - `.publishFailed`: the socket came back but previously published streams could not be
    ///   restored. `isConnected` is still true; call `publish()` again.
    public var onDisconnected: (@Sendable (BandwidthRTCError) -> Void)?

    /// Called with Float32 audio samples for visualization after each mic capture or file chunk.
    /// Array contains 480+ samples (10ms+ at 48kHz).
    public var onLocalAudioLevel: (@Sendable ([Float32]) -> Void)?

    /// Called with Float32 audio samples for visualization after each remote audio playout chunk.
    /// Array contains 480+ samples (10ms+ at 48kHz).
    public var onRemoteAudioLevel: (@Sendable ([Float32]) -> Void)?

    /// Called once per DTMF tone queued for local playback on a published stream (see `sendDtmf`).
    public var onDtmfSent: (@Sendable (DtmfSentEvent) -> Void)?

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

    /// Owns whether a reconnect is running, whether the application asked to disconnect, and
    /// the last close's HTTP status. See `ReconnectState` for why this needs real
    /// synchronization rather than plain vars.
    private let reconnectState = ReconnectState()

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
        // An application-driven connect() always wins over a stale internal retry - wait for
        // any in-flight reconnect to fully stop before this one starts building its own
        // session, so the two can never run establishSession() concurrently against the same
        // peer connection manager.
        await reconnectState.stop()

        self.options = options
        self.authParams = authParams
        reconnectState.setIntentional(false)
        reconnectState.setLastCloseStatusCode(nil)

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

        do {
            try await negotiateSession(sig: sig, authParams: authParams)
        } catch {
            // sig.connect() flips SignalingClient's own isConnected before any RPC exchange
            // happens, so a failure anywhere after that point would otherwise leave it
            // internally marked connected - poisoning every later attempt, whether a fresh
            // connect() or the next iteration of the reconnect loop, with an instant
            // alreadyConnected instead of a real retry. Disconnect it so the same instance
            // (real, or the injected mock in tests) is clean for whatever tries next.
            await sig.disconnect()
            throw error
        }
    }

    private func negotiateSession(sig: any SignalingClientProtocol, authParams: RtcAuthParams) async throws {
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
        pcMgr.onDtmfSent = { [weak self] event in
            self?.onDtmfSent?(event)
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
        reconnectState.setIntentional(true)
        // Wait for a running reconnect to fully stop before tearing the session down -
        // cancellation alone does not stop it, since its awaits inside establishSession() do
        // not observe cancellation on their own. Without this a reconnect that was already
        // mid-attempt can finish after cleanupSession() runs and resurrect the connection this
        // call was meant to end, firing a spurious onReady on a session the application was
        // just told is gone.
        await reconnectState.stop()
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
        guard !reconnectState.isIntentional() else {
            Logger.shared.debug("WebSocket closed after disconnect() - not reconnecting")
            return
        }
        if let fatal = classifyFatalHandshake(reconnectState.getLastCloseStatusCode()) {
            Logger.shared.error("Gateway refused the connection (\(fatal)) - not reconnecting")
            failSession(fatal)
            return
        }
        // If a reconnect is already running, this close is folded into it (it will notice and
        // loop again right before it would otherwise report success) rather than racing a
        // second, competing attempt against the first.
        reconnectState.beginIfIdle { [weak self] in
            await self?.reconnect()
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
            if reconnectState.isIntentional() || Task.isCancelled { return }

            // Discard any "again requested" left over from a close during backoff or a prior,
            // already-retried failed attempt - it does not describe this attempt yet, and
            // leaving it set would make the check below after a real success fire on a stale
            // signal instead of a fresh one.
            _ = reconnectState.consumeAgainRequested()

            Logger.shared.info("Reconnect attempt \(attempt)/\(maxReconnectAttempts)")
            reconnectState.setLastCloseStatusCode(nil)
            do {
                try await establishSession()
            } catch {
                lastError = error
                Logger.shared.warn("Reconnect attempt \(attempt) failed: \(error)")
                if let fatal = fatalHandshakeError(for: error) {
                    Logger.shared.error("Gateway refused the connection - not retrying")
                    await cleanupSession()
                    onDisconnected?(fatal)
                    return
                }
                delay = min(delay * 2, maxReconnectDelay)
                continue
            }

            // The socket is back. Restore published streams once; a failure here leaves the
            // session up but not publishing, so it has to reach the application rather than
            // being retried into a 409 from the gateway.
            do {
                try await republishRetainedStreams()
            } catch {
                // The most likely reason republish itself throws is the socket dying again
                // mid-republish - which is exactly when the close handler sets
                // againRequested rather than scheduling a competing attempt, since this loop
                // is still marked running. Check for that before telling the application the
                // session is up but not publishing; it may not be up at all.
                if reconnectState.consumeAgainRequested() {
                    Logger.shared.warn("Session dropped again during republish - retrying")
                    delay = reconnectBaseDelay
                    continue
                }
                Logger.shared.error("Failed to restore published streams after reconnect: \(error)")
                onDisconnected?(.publishFailed(error.localizedDescription))
                return
            }

            // A close can arrive between establishSession() succeeding and here - the "close"
            // event fires as soon as the socket drops, which can be before republish even
            // finishes - fast enough that handleSocketClosed()'s "already running" check would
            // otherwise fold it into this same attempt and never schedule anything to fix the
            // session it describes. Check the flag it left rather than assuming the session
            // that was healthy a moment ago still is.
            guard reconnectState.consumeAgainRequested() else {
                Logger.shared.info("Reconnected")
                return
            }
            Logger.shared.warn("Session dropped again before reconnect could finish - retrying")
            delay = reconnectBaseDelay
        }

        // Reached by exhausting every attempt; a refusal we will not retry returns from inside
        // the loop above instead of falling through to here.
        Logger.shared.error("Reconnect attempts exhausted: \(lastError)")
        await cleanupSession()
        onDisconnected?(.reconnectFailed(lastError.localizedDescription))
    }

    /// Tear the session down and tell the application, for failures we will not retry.
    private func failSession(_ error: BandwidthRTCError) {
        Task { [weak self] in
            await self?.cleanupSession()
            self?.onDisconnected?(error)
        }
    }

    /// Handshake rejections surfaced through the RPC layer rather than the upgrade response.
    /// The only source of a fatal classification today is `lastCloseStatusCode`, an HTTP status
    /// on the upgrade response - a JSON-RPC error code from a later call, if the gateway ever
    /// sends one for the same condition, is a different numbering scheme entirely and is not
    /// comparable against it, so this does not attempt to guess at one.
    private func fatalHandshakeError(for error: Error) -> BandwidthRTCError? {
        if let fatal = classifyFatalHandshake(reconnectState.getLastCloseStatusCode()) { return fatal }
        if case BandwidthRTCError.invalidToken = error { return .invalidToken }
        return nil
    }

    /// Re-attach every retained published stream to the new publishing peer connection and
    /// renegotiate once for all of them. A no-op when nothing was ever published.
    private func republishRetainedStreams() async throws {
        guard let pcManager = peerConnectionManager, let signalingClient = signaling else {
            throw BandwidthRTCError.notConnected
        }

        // reattachPublishedStreams() only calls the peer connection's own local add(track:) -
        // no network call, no precondition on ICE state - so it is safe to run before waiting
        // for anything and cheap enough to use as the no-op check itself. Only the renegotiation
        // below needs the gateway's side of the peer connection to be connected first.
        guard pcManager.reattachPublishedStreams() > 0 else {
            Logger.shared.debug("Nothing published - skipping republish")
            return
        }

        try await pcManager.waitForPublishIceConnected()

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
            let status = (try? JSONDecoder().decode(WebSocketCloseInfo.self, from: data))?.statusCode
            Logger.shared.warn("WebSocket closed (status=\(status.map(String.init) ?? "none"))")
            self.isConnected = false
            self.hasActiveCall = false
            self.reconnectState.setLastCloseStatusCode(status)
            // The peer connections are dead but are kept (along with the audio device and the
            // retained published streams) until the next attempt resets them. handleSocketClosed
            // decides whether that next attempt happens at all: an application-initiated
            // disconnect or a fatal handshake status (403/409) skips straight to onDisconnected
            // instead of reconnecting into a refusal that will only recur.
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
