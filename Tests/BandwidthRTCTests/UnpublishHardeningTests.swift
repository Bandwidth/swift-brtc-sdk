import XCTest
@testable import BandwidthRTC

/// Tests for hardening `publish()`/`unpublish()` against races, unknown stream ids, and
/// disconnects. Mirrors the JS SDK's unpublish hardening (VAPI-4011, JS commit 3227406).
final class UnpublishHardeningTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        let sut = BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
        sut.reconnectBaseDelay = 10 // keep the reconnect loop asleep during disconnect tests
        return sut
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    private func wait(timeout: TimeInterval = 2, for condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Gap 3: unknown stream id is a no-op

    func testUnpublishUnknownStreamSkipsRenegotiation() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let factory = RTCPeerConnectionFactory()
        let unknownStream = RtcStream(mediaStream: factory.mediaStream(withStreamId: "never-published"), mediaTypes: [.audio])

        try await sut.unpublish(stream: unknownStream)

        XCTAssertEqual(sig.offerSdpCallCount, 0, "an id that matches nothing published must not renegotiate")
    }

    func testUnpublishKnownStreamStillRenegotiatesExactlyOnce() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish()

        let offersBefore = sig.offerSdpCallCount
        try await sut.unpublish(stream: stream)

        XCTAssertEqual(sig.offerSdpCallCount, offersBefore + 1)
    }

    // MARK: - Gap 3: renegotiation failure surfaces a clear, wrapped error

    func testUnpublishWrapsWaitForIceFailure() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish()

        pcManager.shouldThrowOnWaitForIce = BandwidthRTCError.publishFailed("ICE connection timed out")

        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            guard case .unpublishRenegotiationFailed = error as? BandwidthRTCError else {
                XCTFail("Expected unpublishRenegotiationFailed, got \(error)")
                return
            }
        }
        // The stream's tracks were still removed locally before the wait failed.
        XCTAssertEqual(pcManager.removeLocalTracksStreamIdArg, stream.streamId)
    }

    // MARK: - Gap 4: unpublish while disconnected stops tracks locally instead of throwing

    func testUnpublishWhileReconnectingStopsLocallyWithoutThrowing() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream = try await sut.publish()

        let offersBeforeClose = sig.offerSdpCallCount
        let closeData = try JSONEncoder().encode(WebSocketCloseInfo(closeCode: 1001))
        sig.triggerEvent("close", data: closeData)
        await wait { !sut.isConnected }
        XCTAssertFalse(sut.isConnected)
        // Still mid-backoff: the manager is retained, not torn down.
        XCTAssertNotNil(sut.peerConnectionManager)

        // Must not throw, and must not attempt to renegotiate over a session that isn't there.
        try await sut.unpublish(stream: stream)

        XCTAssertEqual(pcManager.removeLocalTracksStreamIdArg, stream.streamId)
        XCTAssertEqual(sig.offerSdpCallCount, offersBeforeClose)
    }

    func testUnpublishBeforeConnectStillThrowsNotConnected() async {
        // Genuinely never connected (no peer connection manager at all) is different from a
        // mid-reconnect disconnect above - there's nothing local to stop either.
        let sut = BandwidthRTCClient(signaling: MockSignalingClient(), peerConnectionManager: nil, audioDevice: MockMixingAudioDevice())
        let factory = RTCPeerConnectionFactory()
        let stream = RtcStream(mediaStream: factory.mediaStream(withStreamId: "s1"), mediaTypes: [.audio])

        await XCTAssertThrowsErrorAsync(try await sut.unpublish(stream: stream)) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    // MARK: - Gap 2: publish-side serialization

    /// Mirrors the JS fix that releases `publishMutex` while `unpublish()` waits for the publish
    /// peer to reconnect (JS commit 3227406, "release publishMutex while unpublish waits for the
    /// publish peer"): that wait can take up to 10s and must not block a concurrent publish().
    func testUnpublishReleasesLockWhileWaitingForPublishIce() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        let stream1 = try await sut.publish()

        // Make unpublish's post-removal ICE wait slow.
        pcManager.waitForIceDelayMs = 150
        let callsBeforeUnpublish = pcManager.waitForPublishIceConnectedCallCount
        let unpublishTask = Task { try await sut.unpublish(stream: stream1) }

        // Let unpublish get past track removal and into its (lock-free) ICE wait before speeding
        // up the knob for the publish() call below - it shares the same mock property.
        await wait { pcManager.waitForPublishIceConnectedCallCount > callsBeforeUnpublish }
        pcManager.waitForIceDelayMs = 0

        let publishStart = Date()
        _ = try await sut.publish()
        let publishDuration = Date().timeIntervalSince(publishStart)

        XCTAssertLessThan(publishDuration, 0.1, "publish() must not block on unpublish()'s in-flight ICE wait")
        try await unpublishTask.value
    }

    /// Mirrors the JS fix serializing publish's attach+negotiate under publishMutex (JS commit
    /// 3227406). Exclusivity itself is proven at the lock level in AsyncMutexTests; this is an
    /// integration smoke test that two overlapping publish() calls don't deadlock or corrupt
    /// each other's state end to end.
    func testConcurrentPublishesCompleteIndependently() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        sig.offerSdpDelayMs = 30
        async let first = sut.publish()
        async let second = sut.publish()
        let (stream1, stream2) = try await (first, second)

        XCTAssertNotEqual(stream1.streamId, stream2.streamId)
        XCTAssertEqual(sig.offerSdpCallCount, 2)
        XCTAssertEqual(pcManager.addLocalTracksCallCount, 2)
    }
}
