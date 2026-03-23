import Foundation
import WebRTC
@testable import BandwidthRTC

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

    // MARK: - Concurrency support

    /// Optional delay (in milliseconds) to simulate ICE waiting on waitForPublishIceConnected.
    var waitForIceDelayMs: UInt64 = 0
    /// If set, waitForPublishIceConnected throws this error.
    var shouldThrowOnWaitForIce: Error? = nil

    // MARK: - Captured calls

    var addLocalTracksAudioArg: Bool? = nil
    var addLocalTracksCallCount = 0
    var setAudioEnabledArg: Bool? = nil
    var setAudioEnabledCallCount = 0
    var sendDtmfArg: String? = nil
    var sendDtmfCallCount = 0
    var cleanupCalled = false
    var cleanupCallCount = 0
    var waitForPublishIceConnectedCallCount = 0
    var handleSubscribeSdpOfferCallCount = 0
    var answerInitialOfferCallCount = 0

    // MARK: - WebRTC factory for creating stub objects

    private static let sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    // MARK: - PeerConnectionManagerProtocol

    @discardableResult
    func setupPublishingPeerConnection() throws -> RTCPeerConnection {
        // Not expected to be called when mock is injected before connect()
        fatalError("setupPublishingPeerConnection called on mock — inject mock before connect()")
    }

    @discardableResult
    func setupSubscribingPeerConnection() throws -> RTCPeerConnection {
        fatalError("setupSubscribingPeerConnection called on mock — inject mock before connect()")
    }

    func waitForPublishIceConnected() async throws {
        waitForPublishIceConnectedCallCount += 1
        if let error = shouldThrowOnWaitForIce { throw error }
        if waitForIceDelayMs > 0 {
            try? await Task.sleep(nanoseconds: waitForIceDelayMs * 1_000_000)
        }
    }

    func answerInitialOffer(sdpOffer: String, pcType: PeerConnectionType) async throws -> String {
        answerInitialOfferCallCount += 1
        if let error = shouldThrowOnAnswerInitialOffer { throw error }
        return answerInitialOfferResult
    }

    func addLocalTracks(audio: Bool) -> RTCMediaStream {
        addLocalTracksAudioArg = audio
        addLocalTracksCallCount += 1
        return Self.sharedFactory.mediaStream(withStreamId: "mock-\(UUID().uuidString)")
    }

    var removeLocalTracksStreamIdArg: String? = nil
    func removeLocalTracks(streamId: String) {
        removeLocalTracksStreamIdArg = streamId
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
        handleSubscribeSdpOfferCallCount += 1
        if let error = shouldThrowOnHandleSubscribeSdpOffer { throw error }
        return handleSubscribeSdpOfferResult
    }

    func setAudioEnabled(_ enabled: Bool) {
        setAudioEnabledArg = enabled
        setAudioEnabledCallCount += 1
    }

    func sendDtmf(_ tone: String) {
        sendDtmfArg = tone
        sendDtmfCallCount += 1
    }

    func cleanup() {
        cleanupCalled = true
        cleanupCallCount += 1
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
