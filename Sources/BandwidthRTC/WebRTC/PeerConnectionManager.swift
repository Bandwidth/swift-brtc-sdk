import Foundation
import WebRTC

/// Manages the dual RTCPeerConnection architecture for BRTC.
/// - Publishing peer connection: sends local audio to the gateway.
/// - Subscribing peer connection: receives remote audio from the gateway.
final class PeerConnectionManager: NSObject, @unchecked Sendable {
    private let log = Logger.shared

    // MARK: - Peer Connection Factory (per-instance, supports custom audio device)

    private static var sslInitialized = false
    let factory: RTCPeerConnectionFactory

    // MARK: - Configuration

    private let rtcConfiguration: RTCConfiguration

    // MARK: - Peer Connections

    private(set) var publishingPC: RTCPeerConnection?
    private(set) var subscribingPC: RTCPeerConnection?

    // MARK: - Data Channels

    private var publishHeartbeatDC: RTCDataChannel?
    private var publishDiagnosticsDC: RTCDataChannel?
    private var subscribeHeartbeatDC: RTCDataChannel?
    private var subscribeDiagnosticsDC: RTCDataChannel?

    // MARK: - Stream Tracking

    private var publishedStreams: [String: RTCMediaStream] = [:]
    private var subscribedStreamMetadata: [String: StreamMetadata] = [:]
    private(set) var subscribeSdpRevision: Int = 0

    // MARK: - Callbacks

    var onStreamAvailable: ((RTCMediaStream, [MediaType]) -> Void)?
    var onStreamUnavailable: ((String) -> Void)?
    var onPublishingIceConnectionStateChange: ((RTCIceConnectionState) -> Void)?
    var onSubscribingIceConnectionStateChange: ((RTCIceConnectionState) -> Void)?

    // ICE connected flag — used to await publish PC readiness before offerSdp
    private(set) var publishIceConnected = false

    // MARK: - Init

    init(options: RtcOptions?, audioDevice: (any RTCAudioDevice)? = nil) {
        if !Self.sslInitialized {
            RTCInitializeSSL()
            Self.sslInitialized = true
        }
        if let audioDevice {
            self.factory = RTCPeerConnectionFactory(
                encoderFactory: nil,
                decoderFactory: nil,
                audioDevice: audioDevice
            )
        } else {
            self.factory = RTCPeerConnectionFactory()
        }

        let config = RTCConfiguration()
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.sdpSemantics = .unifiedPlan
        config.iceServers = options?.iceServers ?? []

        if let policy = options?.iceTransportPolicy {
            config.iceTransportPolicy = policy
        } else {
            config.iceTransportPolicy = .all
        }

        self.rtcConfiguration = config
        super.init()
    }

    // MARK: - Peer Connection Setup

    @discardableResult
    func setupPublishingPeerConnection() throws -> RTCPeerConnection {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        guard let pc = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: self
        ) else {
            throw BandwidthRTCError.connectionFailed("Failed to create publishing peer connection")
        }

        // Don't pre-create data channels — all data channels (__heartbeat__, __diagnostics__)
        // are created by the server in-band via the SDP and received via
        // the ondatachannel / didOpen delegate callback.

        self.publishingPC = pc
        log.debug("Publishing peer connection created")
        return pc
    }

    @discardableResult
    func setupSubscribingPeerConnection() throws -> RTCPeerConnection {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        guard let pc = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: self
        ) else {
            throw BandwidthRTCError.connectionFailed("Failed to create subscribing peer connection")
        }

        // Don't pre-create data channels on the subscribe PC.
        // The server's SDP includes an m=application section that handles
        // data channel setup in-band. Pre-creating negotiated (out-of-band)
        // data channels conflicts with the server's SDP and causes
        // setRemoteDescription to hang in WebRTC M114.

        self.subscribingPC = pc
        log.debug("Subscribing peer connection created (no pre-created data channels)")
        return pc
    }

    /// Wait for the publish peer connection's ICE to reach connected/completed.
    /// This ensures the server is ready to accept offerSdp after the initial handshake.
    /// Throws `BandwidthRTCError.publishFailed` if ICE does not connect within the timeout.
    func waitForPublishIceConnected(timeout: TimeInterval = 10) async throws {
        if publishIceConnected {
            log.debug("Publish ICE already connected, skipping wait")
            return
        }
        // Poll until ICE is connected/completed — avoids a single stored continuation
        // being overwritten if multiple callers wait concurrently.
        let deadline = Date().addingTimeInterval(timeout)
        while !publishIceConnected {
            if Date() >= deadline {
                throw BandwidthRTCError.publishFailed("ICE connection timed out after \(Int(timeout))s")
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
    }

    // MARK: - Initial SDP Handshake

    /// Answer an initial SDP offer from the server (no tracks attached).
    /// Called during connect/init for both publish and subscribe PCs.
    func answerInitialOffer(sdpOffer: String, pcType: PeerConnectionType) async throws -> String {
        let pc: RTCPeerConnection?
        switch pcType {
        case .publish: pc = publishingPC
        case .subscribe: pc = subscribingPC
        }

        guard let pc else {
            throw BandwidthRTCError.sdpNegotiationFailed("\(pcType) peer connection not available")
        }

        let offer = RTCSessionDescription(type: .offer, sdp: sdpOffer)

        // setRemoteDescription
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        // createAnswer + setLocalDescription
        let answerConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answerSdp: String = try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: answerConstraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed("No SDP answer generated"))
                    return
                }
                pc.setLocalDescription(sdp) { error in
                    if let error {
                        continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: sdp.sdp)
                    }
                }
            }
        }

        return answerSdp
    }

    // MARK: - Publishing

    /// Add local audio tracks to the publishing peer connection.
    func addLocalTracks(audio: Bool) -> RTCMediaStream {
        guard let pc = publishingPC else {
            fatalError("Publishing peer connection not set up")
        }

        let streamId = UUID().uuidString
        let stream = factory.mediaStream(withStreamId: streamId)

        if audio {
            let audioSource = factory.audioSource(with: nil)
            let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio-\(streamId)")
            stream.addAudioTrack(audioTrack)
            pc.add(audioTrack, streamIds: [streamId])
            log.debug("Added audio track to publishing PC")
        } else {
            log.debug("addLocalTracks called with audio=false")
        }

        publishedStreams[streamId] = stream
        return stream
    }

    /// Create a client-initiated SDP offer for the publish PC (after tracks are added).
    /// Uses createOffer (not createAnswer) because this is a client-originated renegotiation.
    func createPublishOffer() async throws -> String {
        guard let pc = publishingPC else {
            throw BandwidthRTCError.publishFailed("Publishing peer connection not available")
        }

        // send-only publish PC
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )

        let offerSdp: String = try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: offerConstraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed("No SDP offer generated"))
                    return
                }
                continuation.resume(returning: sdp.sdp)
            }
        }

        log.debug("Publish SDP offer created (client-initiated)")
        return offerSdp
    }

    /// Apply the server's SDP answer to the publish PC after offerSdp returns.
    /// Sets local description (our offer) then remote description (server answer).
    func applyPublishAnswer(localOffer: String, remoteAnswer: String) async throws {
        guard let pc = publishingPC else {
            throw BandwidthRTCError.publishFailed("Publishing peer connection not available")
        }

        let offer = RTCSessionDescription(type: .offer, sdp: localOffer)
        let answer = RTCSessionDescription(type: .answer, sdp: remoteAnswer)

        // setLocalDescription(our offer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { error in
                if let error {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        // setRemoteDescription(server's answer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(answer) { error in
                if let error {
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        log.debug("Publish SDP answer applied (local offer + remote answer)")
    }

    // MARK: - Subscribing

    /// Handle an incoming SDP offer for the subscribing peer connection.
    /// No SDP munging — raw SDP is passed directly.
    /// Returns the SDP answer string to send back to the server.
    func handleSubscribeSdpOffer(
        sdpOffer: String,
        sdpRevision: Int?,
        metadata: [String: StreamMetadata]?
    ) async throws -> String {
        let effectiveRevision = sdpRevision ?? (subscribeSdpRevision + 1)

        // Reject stale offers (but always accept the first one)
        guard effectiveRevision > subscribeSdpRevision || subscribeSdpRevision == 0 else {
            log.warn("Rejecting stale SDP offer (revision \(effectiveRevision) <= \(subscribeSdpRevision))")
            throw BandwidthRTCError.sdpNegotiationFailed("Stale SDP offer")
        }

        if subscribeSdpRevision == 0 {
            log.debug("Accepting first subscribe SDP offer (revision 0→\(effectiveRevision))")
        }

        guard let pc = subscribingPC else {
            throw BandwidthRTCError.sdpNegotiationFailed("Subscribing peer connection not available")
        }

        log.debug("[subscribe] Handling offer (revision=\(effectiveRevision), signalingState=\(pc.signalingState.rawValue))")

        // Update metadata
        if let metadata {
            subscribedStreamMetadata.merge(metadata) { _, new in new }
        }

        // No SDP munging — pass raw SDP directly
        let offer = RTCSessionDescription(type: .offer, sdp: sdpOffer)

        // Step 1: setRemoteDescription
        log.debug("[subscribe] Step 1: setRemoteDescription...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error {
                    self.log.error("[subscribe] setRemoteDescription FAILED: \(error.localizedDescription)")
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                } else {
                    self.log.debug("[subscribe] Step 1: setRemoteDescription SUCCESS")
                    continuation.resume()
                }
            }
        }

        // Step 2: createAnswer
        log.debug("[subscribe] Step 2: createAnswer...")
        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        let answerSdp: String = try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: answerConstraints) { sdp, error in
                if let error {
                    self.log.error("[subscribe] createAnswer FAILED: \(error.localizedDescription)")
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                    return
                }

                guard let sdp else {
                    self.log.error("[subscribe] createAnswer returned nil")
                    continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed("No SDP answer generated"))
                    return
                }

                // Step 3: setLocalDescription — no SDP munging
                self.log.debug("[subscribe] Step 3: setLocalDescription...")
                pc.setLocalDescription(sdp) { error in
                    if let error {
                        self.log.error("[subscribe] setLocalDescription FAILED: \(error.localizedDescription)")
                        continuation.resume(throwing: BandwidthRTCError.sdpNegotiationFailed(error.localizedDescription))
                    } else {
                        self.log.debug("[subscribe] Step 3: setLocalDescription SUCCESS")
                        continuation.resume(returning: sdp.sdp)
                    }
                }
            }
        }

        subscribeSdpRevision = effectiveRevision
        log.debug("[subscribe] Complete (revision=\(effectiveRevision))")
        return answerSdp
    }

    // MARK: - Media Control

    /// Remove local tracks for the given stream from the publishing peer connection.
    /// After calling this, renegotiate by creating a new offer via `createPublishOffer`.
    func removeLocalTracks(streamId: String) {
        guard let pc = publishingPC, let stream = publishedStreams[streamId] else {
            log.warn("removeLocalTracks: stream \(streamId) not found")
            return
        }

        for track in (stream.audioTracks as [RTCMediaStreamTrack]) {
            let matchingTransceivers = pc.transceivers.filter { $0.sender.track?.trackId == track.trackId }
            for transceiver in matchingTransceivers {
                pc.removeTrack(transceiver.sender)
                transceiver.stopInternal()
                log.debug("Removed and stopped transceiver for track \(track.trackId)")
            }
            // Disable the track (native equivalent of track.stop())
            track.isEnabled = false
        }

        publishedStreams.removeValue(forKey: streamId)
        log.debug("Removed local tracks for stream \(streamId)")
    }

    func setAudioEnabled(_ enabled: Bool) {
        for (_, stream) in publishedStreams {
            for track in stream.audioTracks {
                track.isEnabled = enabled
            }
        }
    }

    // MARK: - DTMF

    func sendDtmf(_ tone: String) {
        guard let pc = publishingPC else { return }

        for sender in pc.senders {
            if sender.track?.kind == "audio", let dtmfSender = sender.dtmfSender {
                dtmfSender.insertDtmf(tone, duration: 0.1, interToneGap: 0.05)
                log.debug("Sent DTMF: \(tone)")
                return
            }
        }
        log.warn("No audio sender found for DTMF")
    }

    // MARK: - Audio Stats

    private var audioStatsTask: Task<Void, Never>?

    /// Start periodic logging of audio stats (inbound audio level, packets received, etc.)
    func startAudioStatsLogging(interval: TimeInterval = 3.0) {
        audioStatsTask?.cancel()
        audioStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                self.logAudioStats()
            }
        }
    }

    func stopAudioStatsLogging() {
        audioStatsTask?.cancel()
        audioStatsTask = nil
    }

    private func logAudioStats() {
        // Check subscribe PC for inbound audio
        subscribingPC?.statistics { report in
            for stat in report.statistics.values {
                if stat.type == "inbound-rtp" {
                    if let kind = stat.values["kind"] as? String, kind == "audio" {
                        let packetsReceived = stat.values["packetsReceived"] as? NSNumber ?? 0
                        let bytesReceived = stat.values["bytesReceived"] as? NSNumber ?? 0
                        let audioLevel = stat.values["audioLevel"] as? NSNumber
                        let totalAudioEnergy = stat.values["totalAudioEnergy"] as? NSNumber
                        let jitter = stat.values["jitter"] as? NSNumber
                        self.log.trace("[audio-stats] INBOUND: packets=\(packetsReceived), bytes=\(bytesReceived), audioLevel=\(audioLevel?.stringValue ?? "n/a"), energy=\(totalAudioEnergy?.stringValue ?? "n/a"), jitter=\(jitter?.stringValue ?? "?")")
                    }
                }
            }
        }

        // Check publish PC for outbound audio
        publishingPC?.statistics { report in
            for stat in report.statistics.values {
                if stat.type == "outbound-rtp" {
                    if let kind = stat.values["kind"] as? String, kind == "audio" {
                        let packetsSent = stat.values["packetsSent"] as? NSNumber ?? 0
                        let bytesSent = stat.values["bytesSent"] as? NSNumber ?? 0
                        self.log.trace("[audio-stats] OUTBOUND: packets=\(packetsSent), bytes=\(bytesSent)")
                    }
                }
            }
        }
    }

    // MARK: - Structured Stats

    /// Gather structured call statistics from both peer connections.
    func getCallStats(
        previousInboundBytes: Int,
        previousOutboundBytes: Int,
        previousTimestamp: TimeInterval,
        completion: @escaping (CallStatsSnapshot) -> Void
    ) {
        var snapshot = CallStatsSnapshot()
        let group = DispatchGroup()

        // Inbound stats from subscribe PC
        if let subPC = subscribingPC {
            group.enter()
            subPC.statistics { report in
                var codecId: String?

                for stat in report.statistics.values {
                    if stat.type == "inbound-rtp",
                       let kind = stat.values["kind"] as? String, kind == "audio" {
                        snapshot.packetsReceived = (stat.values["packetsReceived"] as? NSNumber)?.intValue ?? 0
                        snapshot.packetsLost = (stat.values["packetsLost"] as? NSNumber)?.intValue ?? 0
                        snapshot.bytesReceived = (stat.values["bytesReceived"] as? NSNumber)?.intValue ?? 0
                        snapshot.jitter = (stat.values["jitter"] as? NSNumber)?.doubleValue ?? 0
                        snapshot.audioLevel = (stat.values["audioLevel"] as? NSNumber)?.doubleValue ?? 0
                        codecId = stat.values["codecId"] as? String
                    }

                    if stat.type == "candidate-pair",
                       let state = stat.values["state"] as? String, state == "succeeded" {
                        snapshot.roundTripTime = (stat.values["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0
                    }
                }

                // Resolve codec name
                if let codecId, let codecStat = report.statistics[codecId] {
                    if let mimeType = codecStat.values["mimeType"] as? String {
                        snapshot.codec = mimeType.replacingOccurrences(of: "audio/", with: "")
                    }
                }

                group.leave()
            }
        }

        // Outbound stats from publish PC
        if let pubPC = publishingPC {
            group.enter()
            pubPC.statistics { report in
                for stat in report.statistics.values {
                    if stat.type == "outbound-rtp",
                       let kind = stat.values["kind"] as? String, kind == "audio" {
                        snapshot.packetsSent = (stat.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                        snapshot.bytesSent = (stat.values["bytesSent"] as? NSNumber)?.intValue ?? 0
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            snapshot.timestamp = Date().timeIntervalSince1970

            // Calculate bitrate from delta
            let timeDelta = snapshot.timestamp - previousTimestamp
            if timeDelta > 0 && previousTimestamp > 0 {
                let inDelta = max(0, snapshot.bytesReceived - previousInboundBytes)
                let outDelta = max(0, snapshot.bytesSent - previousOutboundBytes)
                snapshot.inboundBitrate = (Double(inDelta) * 8.0) / timeDelta
                snapshot.outboundBitrate = (Double(outDelta) * 8.0) / timeDelta
            }

            completion(snapshot)
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        stopAudioStatsLogging()

        // Stop all tracks
        for (_, stream) in publishedStreams {
            for track in stream.audioTracks { track.isEnabled = false }
        }
        publishedStreams.removeAll()
        subscribedStreamMetadata.removeAll()

        for dc in [publishHeartbeatDC, publishDiagnosticsDC, subscribeHeartbeatDC, subscribeDiagnosticsDC].compactMap({ $0 }) {
            log.debug("Closing data channel: \(dc.label)")
            dc.close()
        }
        publishHeartbeatDC = nil
        publishDiagnosticsDC = nil
        subscribeHeartbeatDC = nil
        subscribeDiagnosticsDC = nil

        publishingPC?.close()
        subscribingPC?.close()
        publishingPC = nil
        subscribingPC = nil

        subscribeSdpRevision = 0
        log.info("Peer connections cleaned up")
    }

}

// MARK: - RTCPeerConnectionDelegate

extension PeerConnectionManager: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log.debug("Signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let pcType = peerConnection === publishingPC ? "publish" : peerConnection === subscribingPC ? "subscribe" : "unknown"
        log.info("Stream added on \(pcType) PC: \(stream.streamId) (audio=\(stream.audioTracks.count), video=\(stream.videoTracks.count))")

        // Log audio track details for debugging
        for track in stream.audioTracks {
            log.debug("  Audio track: \(track.trackId), enabled=\(track.isEnabled), state=\(track.readyState.rawValue)")
        }

        var mediaTypes: [MediaType] = []
        if !stream.audioTracks.isEmpty { mediaTypes.append(.audio) }

        DispatchQueue.main.async { [weak self] in
            self?.onStreamAvailable?(stream, mediaTypes)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        log.info("Stream removed: \(stream.streamId)")

        DispatchQueue.main.async { [weak self] in
            self?.onStreamUnavailable?(stream.streamId)
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        log.debug("Negotiation needed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let pcType = peerConnection === publishingPC ? "publish" : peerConnection === subscribingPC ? "subscribe" : "unknown"
        let stateDesc: String
        switch newState {
        case .new: stateDesc = "new"
        case .checking: stateDesc = "checking"
        case .connected: stateDesc = "connected"
        case .completed: stateDesc = "completed"
        case .failed: stateDesc = "FAILED"
        case .disconnected: stateDesc = "disconnected"
        case .closed: stateDesc = "closed"
        case .count: stateDesc = "count"
        @unknown default: stateDesc = "unknown(\(newState.rawValue))"
        }
        log.debug("ICE connection state [\(pcType)]: \(stateDesc)")

        if peerConnection === publishingPC {
            onPublishingIceConnectionStateChange?(newState)
            if newState == .connected || newState == .completed {
                publishIceConnected = true
            }
        } else if peerConnection === subscribingPC {
            onSubscribingIceConnectionStateChange?(newState)
            // Start audio stats logging when subscribe PC connects
            if newState == .connected || newState == .completed {
                startAudioStatsLogging()
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log.debug("ICE gathering state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // No ICE trickle — candidates are bundled in SDP
        log.debug("ICE candidate generated (bundled in SDP)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        log.debug("ICE candidates removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        let pcType = peerConnection === publishingPC ? "publish" : peerConnection === subscribingPC ? "subscribe" : "unknown"
        log.debug("Data channel opened on \(pcType) PC: \(dataChannel.label) (id=\(dataChannel.channelId))")

        // Handle server-created data channels (created in-band by the server)
        dataChannel.delegate = self

        if dataChannel.label == "__heartbeat__" {
            if peerConnection === publishingPC {
                publishHeartbeatDC = dataChannel
            } else {
                subscribeHeartbeatDC = dataChannel
            }
        } else if dataChannel.label == "__diagnostics__" {
            if peerConnection === publishingPC {
                publishDiagnosticsDC = dataChannel
            } else {
                subscribeDiagnosticsDC = dataChannel
            }
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension PeerConnectionManager: RTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log.debug("Data channel '\(dataChannel.label)' state: \(dataChannel.readyState.rawValue)")
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = String(data: buffer.data, encoding: .utf8) else { return }

        if dataChannel.label == "__heartbeat__" && message == "PING" {
            let pong = RTCDataBuffer(data: "PONG".data(using: .utf8)!, isBinary: false)
            dataChannel.sendData(pong)
            log.debug("Heartbeat PONG sent")
        }
    }
}
