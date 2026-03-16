import Foundation
import WebRTC

/// Protocol abstracting PeerConnectionManager for testability.
protocol PeerConnectionManagerProtocol: AnyObject, Sendable {
    var onStreamAvailable: ((RTCMediaStream, [MediaType]) -> Void)? { get set }
    var onStreamUnavailable: ((String) -> Void)? { get set }
    var onSubscribingIceConnectionStateChange: ((RTCIceConnectionState) -> Void)? { get set }

    @discardableResult
    func setupPublishingPeerConnection() throws -> RTCPeerConnection
    @discardableResult
    func setupSubscribingPeerConnection() throws -> RTCPeerConnection

    func waitForPublishIceConnected() async throws
    func answerInitialOffer(sdpOffer: String, pcType: PeerConnectionType) async throws -> String
    func addLocalTracks(audio: Bool) -> RTCMediaStream
    func removeLocalTracks(streamId: String)
    func createPublishOffer() async throws -> String
    func applyPublishAnswer(localOffer: String, remoteAnswer: String) async throws
    func handleSubscribeSdpOffer(
        sdpOffer: String,
        sdpRevision: Int?,
        metadata: [String: StreamMetadata]?
    ) async throws -> String
    func setAudioEnabled(_ enabled: Bool)
    func sendDtmf(_ tone: String)
    func cleanup()
    func getCallStats(
        previousInboundBytes: Int,
        previousOutboundBytes: Int,
        previousTimestamp: TimeInterval,
        completion: @escaping (CallStatsSnapshot) -> Void
    )
}

extension PeerConnectionManager: PeerConnectionManagerProtocol {}
