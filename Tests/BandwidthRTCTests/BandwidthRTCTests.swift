import XCTest
@testable import BandwidthRTC

final class BandwidthRTCTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    // MARK: - Connection

    func testConnectSetsIsConnected() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        XCTAssertTrue(sut.isConnected)
    }

    func testConnectThrowsIfAlreadyConnected() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .alreadyConnected)
        }
    }

    func testConnectSignalingFailurePropagatesToCaller() async {
        let sig = MockSignalingClient()
        sig.shouldThrowOnConnect = BandwidthRTCError.connectionFailed("network error")
        let sut = makeSUT(signaling: sig)

        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { error in
            guard case .connectionFailed(let detail) = error as? BandwidthRTCError else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
            XCTAssertEqual(detail, "network error")
        }
        XCTAssertFalse(sut.isConnected)
    }

    func testConnectSetMediaPreferencesFailurePropagates() async {
        let sig = MockSignalingClient()
        sig.shouldThrowOnSetMediaPreferences = BandwidthRTCError.rpcError(code: 500, message: "internal error")
        let sut = makeSUT(signaling: sig)

        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { _ in }
        XCTAssertFalse(sut.isConnected)
    }

    func testConnectAnswersPublishOfferWhenPresent() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep",
            deviceId: "dev",
            publishSdpOffer: SdpOffer(peerType: "publish", sdpOffer: "v=0...pub"),
            subscribeSdpOffer: nil
        )
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let calls = sig.answerSdpCalls
        XCTAssertTrue(calls.contains { $0.peerType == "publish" })
    }

    func testConnectAnswersSubscribeOfferWhenPresent() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep",
            deviceId: "dev",
            publishSdpOffer: nil,
            subscribeSdpOffer: SdpOffer(peerType: "subscribe", sdpOffer: "v=0...sub")
        )
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let calls = sig.answerSdpCalls
        XCTAssertTrue(calls.contains { $0.peerType == "subscribe" })
    }

    func testConnectSkipsAnswerWhenOfferAbsent() async throws {
        let sig = MockSignalingClient()
        // Both offers are nil (default)
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        let calls = sig.answerSdpCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testConnectCallsOnReady() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep-xyz",
            deviceId: "dev-abc",
            publishSdpOffer: nil,
            subscribeSdpOffer: nil
        )
        let sut = makeSUT(signaling: sig)

        var receivedMetadata: ReadyMetadata?
        sut.onReady = { metadata in
            receivedMetadata = metadata
        }
        try await sut.connect(authParams: validAuthParams)

        XCTAssertEqual(receivedMetadata?.endpointId, "ep-xyz")
    }

    func testConnectInvalidTokenPropagatesError() async {
        let sig = MockSignalingClient()
        sig.shouldThrowOnSetMediaPreferences = BandwidthRTCError.invalidToken
        let sut = makeSUT(signaling: sig)

        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .invalidToken)
        }
    }

    // MARK: - Disconnect

    func testDisconnectSetsNotConnected() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()
        XCTAssertFalse(sut.isConnected)
    }

    func testDisconnectClearsComponents() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()
        XCTAssertNil(sut.peerConnectionManager)
        XCTAssertNil(sut.signaling)
    }

    func testDisconnectBeforeConnectIsNoOp() async {
        let sut = makeSUT()
        await sut.disconnect()
        XCTAssertFalse(sut.isConnected)
    }

    // MARK: - Publish

    func testPublishThrowsIfNotConnected() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testPublishReturnsStreamWithAudio() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)
        XCTAssertTrue(stream.mediaTypes.contains(.audio))
    }

    func testPublishReturnsStreamWithAlias() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true, alias: "caller")
        XCTAssertEqual(stream.alias, "caller")
    }

    func testPublishPropagatesSignalingError() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        sig.shouldThrowOnOfferSdp = BandwidthRTCError.sdpNegotiationFailed("server rejected")
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            guard case .sdpNegotiationFailed = error as? BandwidthRTCError else {
                XCTFail("Expected sdpNegotiationFailed")
                return
            }
        }
    }

    func testPublishSetsLocalAndRemoteDescription() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish(audio: true)
        // applyPublishAnswer is called once (no throw = success)
        XCTAssertEqual(pcManager.addLocalTracksAudioArg, true)
    }

    // MARK: - Unpublish

    func testUnpublishThrowsIfNotConnected() async {
        let sut = makeSUT()
        let factory = RTCPeerConnectionFactory()
        let stream = RtcStream(mediaStream: factory.mediaStream(withStreamId: "s1"), mediaTypes: [.audio])
        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testUnpublishCallsRemoveLocalTracks() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        try await sut.unpublish(stream: stream)

        XCTAssertEqual(pcManager.removeLocalTracksStreamIdArg, stream.streamId)
    }

    func testUnpublishRenegotiatesWithServer() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        // Reset the offer count captured during publish
        let offerSdpCallsBeforeUnpublish = sig.offerSdpCallCount

        try await sut.unpublish(stream: stream)

        XCTAssertEqual(sig.offerSdpCallCount, offerSdpCallsBeforeUnpublish + 1)
    }

    func testUnpublishPropagatesCreateOfferError() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        pcManager.shouldThrowOnCreatePublishOffer = BandwidthRTCError.sdpNegotiationFailed("offer failed")

        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            guard case .sdpNegotiationFailed = error as? BandwidthRTCError else {
                XCTFail("Expected sdpNegotiationFailed, got \(error)")
                return
            }
        }
    }

    func testUnpublishPropagatesSignalingError() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        sig.shouldThrowOnOfferSdp = BandwidthRTCError.sdpNegotiationFailed("server rejected")

        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            guard case .sdpNegotiationFailed = error as? BandwidthRTCError else {
                XCTFail("Expected sdpNegotiationFailed, got \(error)")
                return
            }
        }
    }

    func testUnpublishPropagatesApplyAnswerError() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        pcManager.shouldThrowOnApplyPublishAnswer = BandwidthRTCError.sdpNegotiationFailed("apply failed")

        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            guard case .sdpNegotiationFailed = error as? BandwidthRTCError else {
                XCTFail("Expected sdpNegotiationFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Media Control

    func testSetMicEnabledForwardsToPCManager() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        sut.setMicEnabled(false)
        XCTAssertEqual(pcManager.setAudioEnabledArg, false)
    }

    func testSetMicEnabledWhenNotConnectedIsNoOp() {
        let sut = makeSUT()
        // Should not crash
        sut.setMicEnabled(false)
    }

    func testSendDtmfForwardsToPCManager() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        sut.sendDtmf("1")
        XCTAssertEqual(pcManager.sendDtmfArg, "1")
    }

    // MARK: - Outbound Calls

    func testRequestOutboundConnectionThrowsIfNotConnected() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(
            try await sut.requestOutboundConnection(id: "ep1", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testRequestOutboundConnectionReturnsResult() async throws {
        let sig = MockSignalingClient()
        sig.requestOutboundResult = OutboundConnectionResult(accepted: true)
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)
        let result = try await sut.requestOutboundConnection(id: "ep1", type: .endpoint)
        XCTAssertTrue(result.accepted)
    }

    func testHangupConnectionThrowsIfNotConnected() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(
            try await sut.hangupConnection(endpoint: "ep1", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testHangupConnectionReturnsResult() async throws {
        let sig = MockSignalingClient()
        sig.hangupResult = HangupResult(result: "bye")
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)
        let result = try await sut.hangupConnection(endpoint: "ep1", type: .endpoint)
        XCTAssertEqual(result.result, "bye")
    }



    // MARK: - Callbacks / Event Handling

    func testOnStreamAvailableForwardedFromPCManager() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var streamCallbackFired = false
        sut.onStreamAvailable = { _ in streamCallbackFired = true }

        // Simulate PCManager firing the callback
        let factory = RTCPeerConnectionFactory()
        let stream = factory.mediaStream(withStreamId: "test-stream")
        pcManager.onStreamAvailable?(stream, [.audio])

        XCTAssertTrue(streamCallbackFired)
    }

    func testCloseEventSetsNotConnected() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        // Simulate close event from signaling
        sig.triggerEvent("close")

        // Give the async closure a tick to run
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(sut.isConnected)
    }
}

// MARK: - Async throw test helper

/// Helper to assert async throwing expressions.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
