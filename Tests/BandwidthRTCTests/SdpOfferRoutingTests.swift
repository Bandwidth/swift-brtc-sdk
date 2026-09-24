import XCTest
@testable import BandwidthRTC

/// Tests for routing a gateway "sdpOffer" notification by `peerType` (see
/// `BandwidthRTCClient.handleSdpOffer`). Mirrors the JS SDK's `handleSdpOffer` /
/// `handlePublishSdpOffer` split (VAPI-4011, JS commit dc6d3e9).
final class SdpOfferRoutingTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    private func wait(timeout: TimeInterval = 2, for condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - peerType == "publish" routes to the publish handler

    func testPublishPeerTypeRoutesToPublishHandlerAndAnswersAsPublish() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let sdpOfferJson = """
        {"sdpOffer":"v=0...restart","peerType":"publish","sdpRevision":3}
        """.data(using: .utf8)!
        sig.triggerEvent("sdpOffer", data: sdpOfferJson)

        await wait { pcManager.handlePublishSdpOfferCallCount == 1 }

        XCTAssertEqual(pcManager.handlePublishSdpOfferCallCount, 1)
        XCTAssertEqual(pcManager.handlePublishSdpOfferRevisionArg, 3)
        XCTAssertEqual(pcManager.handleSubscribeSdpOfferCallCount, 0, "must not also go to the subscribe path")
        XCTAssertEqual(sig.answerSdpCalls.last?.peerType, "publish")
        XCTAssertEqual(sig.answerSdpCalls.last?.sdpAnswer, pcManager.handlePublishSdpOfferResult)
    }

    func testPublishSdpOfferFailureIsLoggedNotThrownToTheEventLoop() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        pcManager.shouldThrowOnHandlePublishSdpOffer = BandwidthRTCError.sdpNegotiationFailed("ICE restart rejected")
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let sdpOfferJson = """
        {"sdpOffer":"v=0...restart","peerType":"publish","sdpRevision":1}
        """.data(using: .utf8)!
        sig.triggerEvent("sdpOffer", data: sdpOfferJson)

        await wait { pcManager.handlePublishSdpOfferCallCount == 1 }

        // The failure is swallowed at the notification handler (there's no caller to propagate
        // to) - no answer is sent, and the session stays up.
        XCTAssertTrue(sig.answerSdpCalls.isEmpty)
        XCTAssertTrue(sut.isConnected)
    }

    // MARK: - Everything else routes to the subscribe handler (unchanged behavior)

    func testSubscribePeerTypeRoutesToSubscribeHandler() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let sdpOfferJson = """
        {"sdpOffer":"v=0...","peerType":"subscribe","sdpRevision":1}
        """.data(using: .utf8)!
        sig.triggerEvent("sdpOffer", data: sdpOfferJson)

        await wait { pcManager.handleSubscribeSdpOfferCallCount == 1 }

        XCTAssertEqual(pcManager.handleSubscribeSdpOfferCallCount, 1)
        XCTAssertEqual(pcManager.handlePublishSdpOfferCallCount, 0)
        XCTAssertEqual(sig.answerSdpCalls.last?.peerType, "subscribe")
    }

    func testMissingPeerTypeDefaultsToSubscribeForOlderGateways() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let sdpOfferJson = """
        {"sdpOffer":"v=0...","sdpRevision":1}
        """.data(using: .utf8)!
        sig.triggerEvent("sdpOffer", data: sdpOfferJson)

        await wait { pcManager.handleSubscribeSdpOfferCallCount == 1 }

        XCTAssertEqual(pcManager.handleSubscribeSdpOfferCallCount, 1)
        XCTAssertEqual(pcManager.handlePublishSdpOfferCallCount, 0)
        XCTAssertEqual(sig.answerSdpCalls.last?.peerType, "subscribe")
    }
}
