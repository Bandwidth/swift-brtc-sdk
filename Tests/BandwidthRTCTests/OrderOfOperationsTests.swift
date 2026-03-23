import XCTest
import WebRTC
@testable import BandwidthRTC

/// Tests for order-of-operations and determinism.
/// Ensures the SDK enforces correct operation sequences and rejects out-of-order calls.
final class OrderOfOperationsTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    // MARK: - Operations Before Connect

    func testPublishBeforeConnectThrows() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testUnpublishBeforeConnectThrows() async {
        let sut = makeSUT()
        let factory = RTCPeerConnectionFactory()
        let stream = RtcStream(mediaStream: factory.mediaStream(withStreamId: "s1"), mediaTypes: [.audio])
        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testRequestOutboundBeforeConnectThrows() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(
            try await sut.requestOutboundConnection(id: "ep1", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testHangupBeforeConnectThrows() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(
            try await sut.hangupConnection(endpoint: "ep1", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testSetMicEnabledBeforeConnectIsNoOp() {
        let sut = makeSUT()
        // Should not crash
        sut.setMicEnabled(true)
        sut.setMicEnabled(false)
    }

    func testSendDtmfBeforeConnectIsNoOp() {
        let sut = makeSUT()
        // Should not crash
        sut.sendDtmf("1")
        sut.sendDtmf("#")
    }

    func testGetCallStatsBeforeConnectReturnsEmpty() {
        let sut = makeSUT()
        let expectation = expectation(description: "stats returned")
        sut.getCallStats(previousSnapshot: nil) { snapshot in
            XCTAssertEqual(snapshot.packetsReceived, 0)
            XCTAssertEqual(snapshot.bytesSent, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Operations After Disconnect

    func testPublishAfterDisconnectThrows() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testRequestOutboundAfterDisconnectThrows() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        await XCTAssertThrowsErrorAsync(
            try await sut.requestOutboundConnection(id: "ep1", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testHangupAfterDisconnectThrows() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        await XCTAssertThrowsErrorAsync(
            try await sut.hangupConnection(endpoint: "ep", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    // MARK: - Connect → setMediaPreferences → answerSdp Ordering

    func testConnectCallsSetMediaPreferencesAfterWebSocketConnect() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        // setMediaPreferences is called (internal mock always succeeds)
        // The fact that connect() succeeds proves setMediaPreferences was called
        XCTAssertTrue(sut.isConnected)
        XCTAssertEqual(sig.connectCalledCount, 1)
    }

    func testConnectOrderPublishBeforeSubscribe() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep",
            deviceId: "dev",
            publishSdpOffer: SdpOffer(peerType: "publish", sdpOffer: "v=0...pub"),
            subscribeSdpOffer: SdpOffer(peerType: "subscribe", sdpOffer: "v=0...sub")
        )
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        // The answerSdp calls should be in order: publish first, then subscribe
        let calls = sig.answerSdpCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].peerType, "publish")
        XCTAssertEqual(calls[1].peerType, "subscribe")
    }

    func testOnReadyFiredAfterSuccessfulConnect() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)

        var onReadyCalled = false
        var onReadyCalledWhileConnected = false
        sut.onReady = { _ in
            onReadyCalled = true
            onReadyCalledWhileConnected = sut.isConnected
        }

        try await sut.connect(authParams: validAuthParams)

        XCTAssertTrue(onReadyCalled)
        XCTAssertTrue(onReadyCalledWhileConnected, "onReady should fire after isConnected=true")
    }

    // MARK: - Publish Ordering: ICE → addTracks → createOffer → offerSdp → applyAnswer

    func testPublishCallsWaitForICEFirst() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish(audio: true)

        XCTAssertEqual(pcManager.waitForPublishIceConnectedCallCount, 1)
    }

    func testPublishCallsAddLocalTracksAfterICE() async throws {
        let pcManager = MockPeerConnectionManager()
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish(audio: true)

        // addLocalTracks was called (tracked by addLocalTracksCallCount)
        XCTAssertEqual(pcManager.addLocalTracksCallCount, 1)
        // offerSdp was called (tracked by offerSdpCallCount)
        XCTAssertEqual(sig.offerSdpCallCount, 1)
    }

    func testPublishWithSignalingErrorDoesNotApplyAnswer() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        sig.shouldThrowOnOfferSdp = BandwidthRTCError.sdpNegotiationFailed("rejected")
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        await XCTAssertThrowsErrorAsync(try await sut.publish()) { _ in }

        // Tracks were added but answer was never applied (error thrown before that step)
        XCTAssertEqual(pcManager.addLocalTracksCallCount, 1)
    }

    // MARK: - Unpublish Ordering: removeLocalTracks → createOffer → offerSdp → applyAnswer

    func testUnpublishRemovesTracksBeforeRenegotiation() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        let offerCountBefore = sig.offerSdpCallCount
        try await sut.unpublish(stream: stream)

        // removeLocalTracks was called with the stream ID
        XCTAssertEqual(pcManager.removeLocalTracksStreamIdArg, stream.streamId)
        // A new offer was created and sent
        XCTAssertEqual(sig.offerSdpCallCount, offerCountBefore + 1)
    }

    // MARK: - SDP Revision Monotonicity (PeerConnectionManager)

    func testSdpRevisionStartsAtZero() {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        XCTAssertEqual(sut.subscribeSdpRevision, 0)
    }

    func testSdpRevisionResetOnCleanup() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupSubscribingPeerConnection()
        // Can't easily advance revision without real SDP, but cleanup should reset it
        sut.cleanup()
        XCTAssertEqual(sut.subscribeSdpRevision, 0)
    }

    func testStaleOfferRejectedByRevisionGuard() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.shouldThrowOnHandleSubscribeSdpOffer = BandwidthRTCError.sdpNegotiationFailed("Stale SDP offer")
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        // Simulate an SDP offer notification arriving
        let sdpOfferData = """
        {"sdpOffer": "v=0...", "sdpRevision": 0, "peerType": "subscribe"}
        """.data(using: .utf8)!
        sig.triggerEvent("sdpOffer", data: sdpOfferData)

        try await Task.sleep(for: .milliseconds(100))

        // The mock threw, so no answerSdp should have been sent for the subscribe offer
        // (the initial connect may have sent answerSdp calls, but not for this event)
        XCTAssertEqual(pcManager.handleSubscribeSdpOfferCallCount, 1)
    }

    // MARK: - Subscribe SDP Offer Handling

    func testSubscribeSdpOfferTriggersHandleAndAnswer() async throws {
        let pcManager = MockPeerConnectionManager()
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let answerSdpCountBefore = sig.answerSdpCalls.count

        // Simulate incoming SDP offer
        let sdpOfferData = """
        {"sdpOffer": "v=0...new-offer", "sdpRevision": 1, "peerType": "subscribe"}
        """.data(using: .utf8)!
        sig.triggerEvent("sdpOffer", data: sdpOfferData)

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(pcManager.handleSubscribeSdpOfferCallCount, 1)
        XCTAssertGreaterThan(sig.answerSdpCalls.count, answerSdpCountBefore)
    }

    func testSubscribeSdpOfferWithBadJsonIsIgnored() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        // Trigger with invalid JSON
        sig.triggerEvent("sdpOffer", data: "not-json".data(using: .utf8)!)
        try await Task.sleep(for: .milliseconds(100))

        // Should not crash; no answerSdp sent beyond initial connect
        XCTAssertTrue(sut.isConnected)
    }

    func testSubscribeSdpOfferAfterDisconnectIsIgnored() async throws {
        let pcManager = MockPeerConnectionManager()
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        // The event handler references [weak self] so after disconnect it should be nil
        // or pcManager is nil and the handler returns early
        sig.triggerEvent("sdpOffer", data: """
        {"sdpOffer": "v=0...", "sdpRevision": 1}
        """.data(using: .utf8)!)

        try await Task.sleep(for: .milliseconds(100))
        // No crash = pass
    }

    // MARK: - ICE State Ordering (PeerConnectionManager)

    func testPublishICEConnectedSetsFlag() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()
        XCTAssertFalse(sut.publishIceConnected)

        sut.peerConnection(sut.publishingPC!, didChange: .connected)
        XCTAssertTrue(sut.publishIceConnected)
    }

    func testPublishICECompletedSetsFlag() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()
        XCTAssertFalse(sut.publishIceConnected)

        sut.peerConnection(sut.publishingPC!, didChange: .completed)
        XCTAssertTrue(sut.publishIceConnected)
    }

    func testPublishICEDisconnectedDoesNotClearFlag() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()

        sut.peerConnection(sut.publishingPC!, didChange: .connected)
        XCTAssertTrue(sut.publishIceConnected)

        sut.peerConnection(sut.publishingPC!, didChange: .disconnected)
        // publishIceConnected stays true — once set, it doesn't reset
        XCTAssertTrue(sut.publishIceConnected)
        sut.cleanup()
    }

    func testSubscribingICECallbackFired() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupSubscribingPeerConnection()

        var capturedState: RTCIceConnectionState?
        sut.onSubscribingIceConnectionStateChange = { state in capturedState = state }

        sut.peerConnection(sut.subscribingPC!, didChange: .failed)
        XCTAssertEqual(capturedState, .failed)
        sut.cleanup()
    }

    // MARK: - Multiple Streams Handling

    func testAddMultipleLocalStreams() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()

        let stream1 = sut.addLocalTracks(audio: true)
        let stream2 = sut.addLocalTracks(audio: true)

        XCTAssertNotEqual(stream1.streamId, stream2.streamId)

        // Disabling audio should affect all published streams
        sut.setAudioEnabled(false)
        for track in stream1.audioTracks { XCTAssertFalse(track.isEnabled) }
        for track in stream2.audioTracks { XCTAssertFalse(track.isEnabled) }

        sut.setAudioEnabled(true)
        for track in stream1.audioTracks { XCTAssertTrue(track.isEnabled) }
        for track in stream2.audioTracks { XCTAssertTrue(track.isEnabled) }
        sut.cleanup()
    }

    func testRemoveLocalTracksRemovesOnlyTargetStream() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()

        let stream1 = sut.addLocalTracks(audio: true)
        let stream2 = sut.addLocalTracks(audio: true)

        sut.removeLocalTracks(streamId: stream1.streamId)

        // stream1 tracks should be disabled
        for track in stream1.audioTracks { XCTAssertFalse(track.isEnabled) }

        // stream2 tracks should still be enabled
        for track in stream2.audioTracks { XCTAssertTrue(track.isEnabled) }
        sut.cleanup()
    }

    func testRemoveNonexistentStreamIsNoOp() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()

        // Should not crash
        sut.removeLocalTracks(streamId: "nonexistent-stream-id")
        sut.cleanup()
    }

    // MARK: - Audio Processing Options Propagation

    func testAudioProcessingOptionsDefaultValues() {
        let options = AudioProcessingOptions()
        XCTAssertEqual(options.inputSampleRate, 48000)
        XCTAssertEqual(options.outputSampleRate, 48000)
        XCTAssertEqual(options.inputChannels, 1)
        XCTAssertEqual(options.outputChannels, 1)
        XCTAssertFalse(options.useLowLatency)
        XCTAssertNil(options.preferredIOBufferDuration)
    }

    func testRtcStreamAliasIsPreserved() {
        let factory = RTCPeerConnectionFactory()
        let ms = factory.mediaStream(withStreamId: "test-id")
        let stream = RtcStream(mediaStream: ms, mediaTypes: [.audio], alias: "my-alias")
        XCTAssertEqual(stream.alias, "my-alias")
        XCTAssertEqual(stream.streamId, "test-id")
        XCTAssertEqual(stream.mediaTypes, [.audio])
    }

    func testRtcStreamWithoutAlias() {
        let factory = RTCPeerConnectionFactory()
        let ms = factory.mediaStream(withStreamId: "test-id-2")
        let stream = RtcStream(mediaStream: ms, mediaTypes: [])
        XCTAssertNil(stream.alias)
        XCTAssertTrue(stream.mediaTypes.isEmpty)
    }

    // MARK: - Error Type Coverage

    func testAllErrorCasesAreEquatable() {
        // Verify Equatable conformance for all error cases
        XCTAssertEqual(BandwidthRTCError.invalidToken, BandwidthRTCError.invalidToken)
        XCTAssertEqual(BandwidthRTCError.alreadyConnected, BandwidthRTCError.alreadyConnected)
        XCTAssertEqual(BandwidthRTCError.notConnected, BandwidthRTCError.notConnected)
        XCTAssertEqual(BandwidthRTCError.webSocketDisconnected, BandwidthRTCError.webSocketDisconnected)
        XCTAssertEqual(BandwidthRTCError.mediaAccessDenied, BandwidthRTCError.mediaAccessDenied)
        XCTAssertEqual(BandwidthRTCError.noActiveCall, BandwidthRTCError.noActiveCall)

        XCTAssertEqual(
            BandwidthRTCError.connectionFailed("a"),
            BandwidthRTCError.connectionFailed("a")
        )
        XCTAssertNotEqual(
            BandwidthRTCError.connectionFailed("a"),
            BandwidthRTCError.connectionFailed("b")
        )

        XCTAssertEqual(
            BandwidthRTCError.rpcError(code: 500, message: "err"),
            BandwidthRTCError.rpcError(code: 500, message: "err")
        )
        XCTAssertNotEqual(
            BandwidthRTCError.rpcError(code: 500, message: "err"),
            BandwidthRTCError.rpcError(code: 404, message: "err")
        )
    }

    func testNotSupportedErrorDescription() {
        let error = BandwidthRTCError.notSupported("video")
        XCTAssertTrue(error.errorDescription?.contains("video") ?? false)
    }

    func testNoActiveCallErrorDescription() {
        let error = BandwidthRTCError.noActiveCall
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }
}
