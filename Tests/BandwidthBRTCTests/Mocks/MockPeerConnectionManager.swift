import Foundation
import WebRTC
@testable import BandwidthBRTC

/// Mock PeerConnectionManager for testing BandwidthRTC without real WebRTC.
final class MockPeerConnectionManager: @unchecked Sendable, PeerConnectionManagerProtocol {

    // MARK: - Callbacks (protocol requirement)

    var onStreamAvailable: ((RTCMediaStream, [MediaType]) -> Void)?
    var onStreamUnavailable: ((String) -> Void)?
    var onSubscribingIceConnectionStateChange: ((RTCIceConnectionState) -> Void)?

    // MARK: - Configuration

    var shouldThrowOnCreatePublishOffer: Error? = nil
    var shouldThrowOnApplyPublishAnswer: Error? = nil
    var shouldThrowOnAnswerInitialOffer: Error? = nil
    var shouldThrowOnHandleSubscribeSdpOffer: Error? = nil

    var answerInitialOfferResult: String = "mock-answer-sdp"
    var createPublishOfferResult: String = "mock-offer-sdp"
    var handleSubscribeSdpOfferResult: String = "mock-subscribe-answer"

    // MARK: - Captured calls

    var addLocalTracksAudioArg: Bool? = nil
    var setAudioEnabledArg: Bool? = nil
    var sendDtmfArg: String? = nil
    var cleanupCalled = false
    var waitForPublishIceConnectedCallCount = 0

    // MARK: - WebRTC factory for creating stub objects

    private static let sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    // MARK: - PeerConnectionManagerProtocol

    @discardableResult
    func setupPublishingPeerConnection() -> RTCPeerConnection {
        // Not expected to be called when mock is injected before connect()
        fatalError("setupPublishingPeerConnection called on mock — inject mock before connect()")
    }

    @discardableResult
    func setupSubscribingPeerConnection() -> RTCPeerConnection {
        fatalError("setupSubscribingPeerConnection called on mock — inject mock before connect()")
    }

    func waitForPublishIceConnected() async {
        waitForPublishIceConnectedCallCount += 1
    }

    func answerInitialOffer(sdpOffer: String, pcType: PeerConnectionType) async throws -> String {
        if let error = shouldThrowOnAnswerInitialOffer { throw error }
        return answerInitialOfferResult
    }

    func addLocalTracks(audio: Bool) -> RTCMediaStream {
        addLocalTracksAudioArg = audio
        return Self.sharedFactory.mediaStream(withStreamId: "mock-\(UUID().uuidString)")
    }

    func createPublishOffer() async throws -> String {
        if let error = shouldThrowOnCreatePublishOffer { throw error }
        return createPublishOfferResult
    }

    func applyPublishAnswer(localOffer: String, remoteAnswer: String) async throws {
        if let error = shouldThrowOnApplyPublishAnswer { throw error }
    }

    func handleSubscribeSdpOffer(
        sdpOffer: String,
        sdpRevision: Int?,
        metadata: [String: StreamMetadata]?
    ) async throws -> String {
        if let error = shouldThrowOnHandleSubscribeSdpOffer { throw error }
        return handleSubscribeSdpOfferResult
    }

    func setAudioEnabled(_ enabled: Bool) {
        setAudioEnabledArg = enabled
    }

    func sendDtmf(_ tone: String) {
        sendDtmfArg = tone
    }

    func cleanup() {
        cleanupCalled = true
    }

    func getCallStats(
        previousInboundBytes: Int,
        previousOutboundBytes: Int,
        previousTimestamp: TimeInterval,
        completion: @escaping (CallStatsSnapshot) -> Void
    ) {
        completion(CallStatsSnapshot())
    }
}
