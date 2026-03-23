import XCTest
import WebRTC
@testable import BandwidthRTC

/// Tests for resource sharing, lifecycle management, cleanup correctness,
/// and reconnection scenarios.
final class ResourceLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    // MARK: - Disconnect Cleanup

    func testDisconnectCallsCleanupOnPCManager() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        XCTAssertTrue(pcManager.cleanupCalled)
        XCTAssertEqual(pcManager.cleanupCallCount, 1)
    }

    func testDisconnectCallsDisconnectOnSignaling() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        XCTAssertEqual(sig.disconnectCalledCount, 1)
    }

    func testDisconnectNilsOutPeerConnectionManager() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        XCTAssertNotNil(sut.peerConnectionManager)

        await sut.disconnect()
        XCTAssertNil(sut.peerConnectionManager)
    }

    func testDisconnectNilsOutSignaling() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        XCTAssertNotNil(sut.signaling)

        await sut.disconnect()
        XCTAssertNil(sut.signaling)
    }

    func testDisconnectNilsOutMixingDevice() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        // MixingDevice is nil when using mock (cast to MixingAudioDevice fails)
        // but isConnected should be false
        await sut.disconnect()
        XCTAssertNil(sut.mixingDevice)
    }

    func testMultipleDisconnectsAreIdempotent() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        await sut.disconnect()
        await sut.disconnect()
        await sut.disconnect()

        // Should not crash, disconnect signaling only once (first call)
        // Subsequent calls see signaling as nil
        XCTAssertFalse(sut.isConnected)
        XCTAssertEqual(sig.disconnectCalledCount, 1)
    }

    func testDisconnectBeforeConnectIsNoOpAndDoesNotCrash() async {
        let sut = makeSUT()
        await sut.disconnect()
        XCTAssertFalse(sut.isConnected)
    }

    // MARK: - Close Event Cleanup

    func testCloseEventCleansUpPeerConnectionManager() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        sig.triggerEvent("close")
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(sut.isConnected)
        XCTAssertTrue(pcManager.cleanupCalled)
        XCTAssertNil(sut.peerConnectionManager)
    }

    func testCloseEventNilsMixingDevice() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        sig.triggerEvent("close")
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(sut.mixingDevice)
    }

    func testOperationsAfterCloseEventFail() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        sig.triggerEvent("close")
        try await Task.sleep(for: .milliseconds(50))

        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    // MARK: - Publish / Unpublish Resource Lifecycle

    func testPublishCreatesLocalTracks() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish(audio: true)

        XCTAssertEqual(pcManager.addLocalTracksAudioArg, true)
        XCTAssertEqual(pcManager.addLocalTracksCallCount, 1)
    }

    func testUnpublishRemovesLocalTracks() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: true)

        try await sut.unpublish(stream: stream)
        XCTAssertEqual(pcManager.removeLocalTracksStreamIdArg, stream.streamId)
    }

    func testPublishUnpublishPublishCycle() async throws {
        let pcManager = MockPeerConnectionManager()
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        // First publish
        let stream1 = try await sut.publish(audio: true)
        XCTAssertEqual(pcManager.addLocalTracksCallCount, 1)

        // Unpublish
        try await sut.unpublish(stream: stream1)
        XCTAssertNotNil(pcManager.removeLocalTracksStreamIdArg)

        // Second publish
        let stream2 = try await sut.publish(audio: true)
        XCTAssertEqual(pcManager.addLocalTracksCallCount, 2)

        // Different streams
        XCTAssertNotEqual(stream1.streamId, stream2.streamId)
    }

    func testPublishWithAudioFalse() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish(audio: false)

        XCTAssertEqual(pcManager.addLocalTracksAudioArg, false)
        XCTAssertTrue(stream.mediaTypes.isEmpty)
    }

    // MARK: - Connection with SDP Offers

    func testConnectWithBothOffersAnswersBoth() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep-1",
            deviceId: "dev-1",
            publishSdpOffer: SdpOffer(peerType: "publish", sdpOffer: "v=0...pub"),
            subscribeSdpOffer: SdpOffer(peerType: "subscribe", sdpOffer: "v=0...sub")
        )
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let calls = sig.answerSdpCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.contains { $0.peerType == "publish" })
        XCTAssertTrue(calls.contains { $0.peerType == "subscribe" })
        XCTAssertEqual(pcManager.answerInitialOfferCallCount, 2)
    }

    func testConnectWithNoOffersSkipsAnswers() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        XCTAssertTrue(sig.answerSdpCalls.isEmpty)
    }

    func testConnectAnswerInitialOfferFailurePropagates() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep",
            deviceId: "dev",
            publishSdpOffer: SdpOffer(peerType: "publish", sdpOffer: "v=0...pub"),
            subscribeSdpOffer: nil
        )
        let pcManager = MockPeerConnectionManager()
        pcManager.shouldThrowOnAnswerInitialOffer = BandwidthRTCError.sdpNegotiationFailed("failed")
        let sut = makeSUT(signaling: sig, pcManager: pcManager)

        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { error in
            guard case .sdpNegotiationFailed = error as? BandwidthRTCError else {
                XCTFail("Expected sdpNegotiationFailed, got \(error)")
                return
            }
        }
        XCTAssertFalse(sut.isConnected)
    }

    func testConnectAnswerSdpSignalingFailurePropagates() async throws {
        let sig = MockSignalingClient()
        sig.setMediaPreferencesResult = SetMediaPreferencesResult(
            endpointId: "ep",
            deviceId: "dev",
            publishSdpOffer: SdpOffer(peerType: "publish", sdpOffer: "v=0...pub"),
            subscribeSdpOffer: nil
        )
        sig.shouldThrowOnAnswerSdp = BandwidthRTCError.signalingError("network error")
        let sut = makeSUT(signaling: sig)

        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { error in
            guard case .signalingError = error as? BandwidthRTCError else {
                XCTFail("Expected signalingError, got \(error)")
                return
            }
        }
        XCTAssertFalse(sut.isConnected)
    }

    // MARK: - Event Handler Registration

    func testEventHandlersRegisteredOnConnect() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        let events = sig.registeredEvents
        XCTAssertTrue(events.contains("sdpOffer"))
        XCTAssertTrue(events.contains("ready"))
        XCTAssertTrue(events.contains("established"))
        XCTAssertTrue(events.contains("close"))
    }

    func testReadyEventDeliversToCaller() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)

        var readyMetadata: ReadyMetadata?
        sut.onReady = { metadata in readyMetadata = metadata }

        try await sut.connect(authParams: validAuthParams)

        // First onReady comes from connect() itself
        XCTAssertNotNil(readyMetadata)
        XCTAssertEqual(readyMetadata?.endpointId, "mock-endpoint")
    }

    func testReadyEventWithJsonPayload() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)

        var receivedMetadata: ReadyMetadata?
        sut.onReady = { metadata in receivedMetadata = metadata }

        try await sut.connect(authParams: validAuthParams)
        // Reset from connect's onReady call
        receivedMetadata = nil

        // Simulate server sending a ready event
        let jsonData = """
        {"endpointId": "ep-from-event", "deviceId": "dev-from-event"}
        """.data(using: .utf8)!
        sig.triggerEvent("ready", data: jsonData)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(receivedMetadata?.endpointId, "ep-from-event")
    }

    func testReadyEventWithEmptyDataCreatesDefaultMetadata() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)

        var receivedMetadata: ReadyMetadata?
        sut.onReady = { metadata in receivedMetadata = metadata }

        try await sut.connect(authParams: validAuthParams)
        receivedMetadata = nil

        sig.triggerEvent("ready", data: Data())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(receivedMetadata)
    }

    // MARK: - Outbound Connection Lifecycle

    func testRequestOutboundConnectionForwardsParameters() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        _ = try await sut.requestOutboundConnection(id: "+15551234567", type: .phoneNumber)

        XCTAssertEqual(sig.requestOutboundCalls.count, 1)
        XCTAssertEqual(sig.requestOutboundCalls.first?.id, "+15551234567")
        XCTAssertEqual(sig.requestOutboundCalls.first?.type, .phoneNumber)
    }

    func testHangupConnectionForwardsParameters() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        _ = try await sut.hangupConnection(endpoint: "ep-123", type: .endpoint)

        XCTAssertEqual(sig.hangupCalls.count, 1)
        XCTAssertEqual(sig.hangupCalls.first?.endpoint, "ep-123")
        XCTAssertEqual(sig.hangupCalls.first?.type, .endpoint)
    }

    func testRequestOutboundPropagatesError() async throws {
        let sig = MockSignalingClient()
        sig.shouldThrowOnRequestOutbound = BandwidthRTCError.rpcError(code: 500, message: "server error")
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        await XCTAssertThrowsErrorAsync(
            try await sut.requestOutboundConnection(id: "ep", type: .endpoint)
        ) { error in
            guard case .rpcError(let code, _) = error as? BandwidthRTCError else {
                XCTFail("Expected rpcError")
                return
            }
            XCTAssertEqual(code, 500)
        }
    }

    func testHangupPropagatesError() async throws {
        let sig = MockSignalingClient()
        sig.shouldThrowOnHangup = BandwidthRTCError.rpcError(code: 404, message: "not found")
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        await XCTAssertThrowsErrorAsync(
            try await sut.hangupConnection(endpoint: "ep", type: .endpoint)
        ) { error in
            guard case .rpcError(let code, _) = error as? BandwidthRTCError else {
                XCTFail("Expected rpcError")
                return
            }
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: - PeerConnectionManager Cleanup Details

    func testPeerConnectionManagerCleanupNilsAllPCs() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()
        try sut.setupSubscribingPeerConnection()

        XCTAssertNotNil(sut.publishingPC)
        XCTAssertNotNil(sut.subscribingPC)

        sut.cleanup()

        XCTAssertNil(sut.publishingPC)
        XCTAssertNil(sut.subscribingPC)
    }

    func testPeerConnectionManagerCleanupResetsSdpRevision() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        // subscribeSdpRevision starts at 0, cleanup resets it
        sut.cleanup()
        XCTAssertEqual(sut.subscribeSdpRevision, 0)
    }

    func testPeerConnectionManagerDoubleCleanup() throws {
        let sut = PeerConnectionManager(options: nil, audioDevice: nil)
        try sut.setupPublishingPeerConnection()
        sut.cleanup()
        sut.cleanup() // Second cleanup should not crash
        XCTAssertNil(sut.publishingPC)
    }

    // MARK: - CallStatsSnapshot Default Values

    func testCallStatsSnapshotDefaults() {
        let snapshot = CallStatsSnapshot()
        XCTAssertEqual(snapshot.packetsReceived, 0)
        XCTAssertEqual(snapshot.packetsLost, 0)
        XCTAssertEqual(snapshot.bytesReceived, 0)
        XCTAssertEqual(snapshot.jitter, 0)
        XCTAssertEqual(snapshot.audioLevel, 0)
        XCTAssertEqual(snapshot.packetsSent, 0)
        XCTAssertEqual(snapshot.bytesSent, 0)
        XCTAssertEqual(snapshot.roundTripTime, 0)
        XCTAssertEqual(snapshot.codec, "unknown")
        XCTAssertEqual(snapshot.inboundBitrate, 0)
        XCTAssertEqual(snapshot.outboundBitrate, 0)
        XCTAssertEqual(snapshot.timestamp, 0)
    }

    // MARK: - Log Level Configuration

    func testSetLogLevelDoesNotCrash() {
        let sut = BandwidthRTCClient()
        sut.setLogLevel(.off)
        sut.setLogLevel(.error)
        sut.setLogLevel(.warn)
        sut.setLogLevel(.info)
        sut.setLogLevel(.debug)
        sut.setLogLevel(.trace)
    }
}
