import XCTest
import WebRTC
@testable import BandwidthRTC

/// Tests for reconnecting after an unexpected websocket close and restoring published streams.
final class ReconnectTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        let sut = BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
        // Keep the backoff out of wall-clock territory.
        sut.reconnectBaseDelay = 0.02
        return sut
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    /// Poll until `condition` holds or the timeout expires.
    private func wait(timeout: TimeInterval = 2, for condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Replay is a no-op on a first connect

    func testFirstConnectDoesNotReplayStreams() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)

        try await sut.connect(authParams: validAuthParams)

        XCTAssertEqual(pcManager.reattachPublishedStreamsCallCount, 0)
        XCTAssertEqual(sig.offerSdpCallCount, 0)
        await sut.disconnect()
    }

    func testReconnectWithNothingPublishedDoesNotRenegotiate() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        sig.triggerEvent("close")
        await wait { sut.isConnected }

        XCTAssertTrue(sut.isConnected)
        XCTAssertEqual(sig.connectCalledCount, 2)
        // Reattach is consulted, finds nothing retained, and no offer is sent.
        XCTAssertEqual(pcManager.reattachPublishedStreamsCallCount, 1)
        XCTAssertEqual(sig.offerSdpCallCount, 0)
        await sut.disconnect()
    }

    // MARK: - Replay on reconnect

    func testReconnectReplaysPublishedStreamsWithOneRenegotiation() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish()
        _ = try await sut.publish()
        XCTAssertEqual(sig.offerSdpCallCount, 2)

        sig.triggerEvent("close")
        await wait { sut.isConnected }

        XCTAssertTrue(sut.isConnected)
        XCTAssertEqual(pcManager.reattachPublishedStreamsCallCount, 1)
        // Two retained streams, one renegotiation for both.
        XCTAssertEqual(sig.offerSdpCallCount, 3)
        await sut.disconnect()
    }

    func testReconnectResetsPeerConnectionsInsteadOfCreatingNewManager() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        for expectedConnects in 2...4 {
            sig.triggerEvent("close")
            await wait { sig.connectCalledCount == expectedConnects && sut.isConnected }
            XCTAssertEqual(sig.connectCalledCount, expectedConnects)
        }

        // Same manager throughout - each attempt closes the dead peer connections before
        // opening new ones, so nothing is leaked.
        XCTAssertTrue(sut.peerConnectionManager === pcManager)
        XCTAssertEqual(pcManager.resetPeerConnectionsCallCount, 4)
        XCTAssertEqual(pcManager.cleanupCallCount, 0)
        await sut.disconnect()
    }

    func testRepublishFailureSurfacesToApplication() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish()

        let errorBox = ErrorBox()
        sut.onDisconnected = { errorBox.value = $0 }
        sig.shouldThrowOnOfferSdp = BandwidthRTCError.sdpNegotiationFailed("boom")

        sig.triggerEvent("close")
        await wait { errorBox.value != nil }

        guard case .publishFailed = errorBox.value as? BandwidthRTCError else {
            return XCTFail("Expected publishFailed, got \(String(describing: errorBox.value))")
        }
        await sut.disconnect()
    }

    /// A close arriving while republish is still in flight must fold into a fresh attempt
    /// instead of the failing attempt reporting `.publishFailed` on a session that is already
    /// gone again by the time it fails.
    func testCloseDuringRepublishRetriesInsteadOfReportingFailure() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        _ = try await sut.publish()

        let errorBox = ErrorBox()
        sut.onDisconnected = { errorBox.value = $0 }

        sig.shouldThrowOnOfferSdp = BandwidthRTCError.sdpNegotiationFailed("boom")
        sig.offerSdpDelayMs = 50

        sig.triggerEvent("close")
        // Let the attempt get past establishSession() and into the delayed republish offer.
        try await Task.sleep(nanoseconds: 20_000_000)
        // A second close arrives while that offer is still pending.
        sig.triggerEvent("close")
        // Let the retry that follows succeed.
        sig.shouldThrowOnOfferSdp = nil
        sig.offerSdpDelayMs = 0

        await wait { sut.isConnected && pcManager.reattachPublishedStreamsCallCount == 2 }

        XCTAssertNil(errorBox.value)
        XCTAssertTrue(sut.isConnected)
        await sut.disconnect()
    }

    // MARK: - Application-initiated disconnect

    func testNoReconnectAfterExplicitDisconnect() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        await sut.disconnect()
        // A close racing in behind disconnect() must not resurrect the session.
        sig.triggerEvent("close")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(sut.isConnected)
        XCTAssertEqual(sig.connectCalledCount, 1)
    }

    // MARK: - Fatal handshake rejections

    func testGatewayRefusalDoesNotReconnect() async throws {
        let expected: [Int: BandwidthRTCError] = [403: .invalidToken, 409: .endpointOccupied]
        for (status, expectedError) in expected {
            let sig = MockSignalingClient()
            let sut = makeSUT(signaling: sig)
            try await sut.connect(authParams: validAuthParams)

            let errorBox = ErrorBox()
            sut.onDisconnected = { errorBox.value = $0 }

            let info = try JSONEncoder().encode(WebSocketCloseInfo(statusCode: status))
            sig.triggerEvent("close", data: info)
            await wait { errorBox.value != nil }

            XCTAssertFalse(sut.isConnected, "status \(status)")
            XCTAssertEqual(sig.connectCalledCount, 1, "status \(status) must not be retried")
            XCTAssertEqual(errorBox.value as? BandwidthRTCError, expectedError, "status \(status)")
        }
    }

    func testExhaustedReconnectTearsDownAndReportsError() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        let errorBox = ErrorBox()
        sut.onDisconnected = { errorBox.value = $0 }
        sig.shouldThrowOnConnect = BandwidthRTCError.connectionFailed("network down")

        sig.triggerEvent("close")
        await wait(timeout: 5) { errorBox.value != nil }

        XCTAssertFalse(sut.isConnected)
        XCTAssertNil(sut.peerConnectionManager)
        guard case .reconnectFailed = errorBox.value as? BandwidthRTCError else {
            return XCTFail("Expected reconnectFailed, got \(String(describing: errorBox.value))")
        }
    }

    // MARK: - Track re-acquisition (real PeerConnectionManager)

    func testReattachProducesLiveSendersOnTheNewPeerConnection() throws {
        let manager = PeerConnectionManager(options: nil, audioDevice: nil)
        defer { manager.cleanup() }
        try manager.setupPublishingPeerConnection()

        let stream = manager.addLocalTracks(audio: true)
        let streamId = stream.streamId
        let originalTrackId = stream.audioTracks[0].trackId

        // Reconnect: the peer connection the tracks were attached to is closed and replaced.
        try manager.resetPeerConnections()
        XCTAssertEqual(manager.publishingPC?.senders.count, 0)

        XCTAssertEqual(manager.reattachPublishedStreams(), 1)

        // Stream identity survives, so an RtcStream the application still holds stays valid.
        XCTAssertEqual(stream.streamId, streamId)
        XCTAssertEqual(stream.audioTracks.count, 1)

        // Whatever ended, what is attached is live and enabled - a dead track here would produce
        // a sender that never sends RTP.
        let attached = stream.audioTracks[0]
        XCTAssertEqual(attached.trackId, originalTrackId)
        XCTAssertEqual(attached.readyState, .live)
        XCTAssertTrue(attached.isEnabled)

        let senderTrackIds = manager.publishingPC?.senders.compactMap { $0.track?.trackId } ?? []
        XCTAssertEqual(senderTrackIds, [originalTrackId])
    }

    func testReattachReacquiresEndedTracks() throws {
        let manager = PeerConnectionManager(options: nil, audioDevice: nil)
        defer { manager.cleanup() }
        try manager.setupPublishingPeerConnection()

        let stream = manager.addLocalTracks(audio: true)
        let endedTrack = stream.audioTracks[0]
        let trackId = endedTrack.trackId

        try manager.resetPeerConnections()
        // The track ended while the session was down.
        manager.isTrackLive = { _ in false }

        XCTAssertEqual(manager.reattachPublishedStreams(), 1)

        // The dead track was replaced, not re-attached: re-attaching it would produce a sender
        // that never sends RTP, which the gateway sees as a connected-but-silent endpoint.
        XCTAssertEqual(stream.audioTracks.count, 1)
        let replacement = stream.audioTracks[0]
        XCTAssertFalse(replacement.isEqual(endedTrack))
        XCTAssertEqual(replacement.trackId, trackId)
        XCTAssertEqual(replacement.readyState, .live)
        XCTAssertTrue(replacement.isEnabled)

        let senderTracks = manager.publishingPC?.senders.compactMap { $0.track } ?? []
        XCTAssertEqual(senderTracks.count, 1)
        XCTAssertTrue(senderTracks[0].isEqual(replacement))
        XCTAssertFalse(senderTracks[0].isEqual(endedTrack))
    }

    func testReattachWithNothingPublishedReturnsZero() throws {
        let manager = PeerConnectionManager(options: nil, audioDevice: nil)
        defer { manager.cleanup() }
        try manager.setupPublishingPeerConnection()

        XCTAssertEqual(manager.reattachPublishedStreams(), 0)
        XCTAssertEqual(manager.publishingPC?.senders.count, 0)
    }

    func testCleanupDropsRetainedStreams() throws {
        let manager = PeerConnectionManager(options: nil, audioDevice: nil)
        try manager.setupPublishingPeerConnection()
        _ = manager.addLocalTracks(audio: true)

        manager.cleanup()
        try manager.setupPublishingPeerConnection()
        XCTAssertEqual(manager.reattachPublishedStreams(), 0)
        manager.cleanup()
    }
}

/// Box for capturing a callback error from a non-escaping test context.
private final class ErrorBox: @unchecked Sendable {
    var value: Error?
}
