import XCTest
import WebRTC
@testable import BandwidthRTC

/// Tests for concurrency safety, thread-safety of callbacks, and concurrent access patterns.
/// Ensures the SDK behaves deterministically under simultaneous operations.
final class ConcurrencyTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        signaling: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager = MockPeerConnectionManager(),
        audioDevice: MockMixingAudioDevice = MockMixingAudioDevice()
    ) -> BandwidthRTCClient {
        BandwidthRTCClient(signaling: signaling, peerConnectionManager: pcManager, audioDevice: audioDevice)
    }

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    // MARK: - Concurrent Connect Attempts

    func testDoubleConnectSecondCallThrowsAlreadyConnected() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)

        // Second connect should throw alreadyConnected
        await XCTAssertThrowsErrorAsync(try await sut.connect(authParams: validAuthParams)) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .alreadyConnected)
        }
    }

    func testConcurrentConnectAndDisconnect() async throws {
        // Verify that concurrent connect and disconnect don't crash
        let sig = MockSignalingClient()
        sig.connectDelayMs = 50
        let sut = makeSUT(signaling: sig)

        let connectTask = Task {
            try? await sut.connect(authParams: self.validAuthParams)
        }

        // Start disconnect slightly after
        try? await Task.sleep(for: .milliseconds(20))
        let disconnectTask = Task {
            await sut.disconnect()
        }

        await connectTask.value
        await disconnectTask.value

        // After both complete, the client should be in a consistent state
        // (either connected or disconnected — no crash)
        // The key assertion is that we didn't crash or deadlock
    }

    func testRapidConnectDisconnectCycles() async throws {
        let sut = makeSUT()
        // Rapidly cycle connect/disconnect 5 times
        for _ in 0..<5 {
            let sig = MockSignalingClient()
            let pcManager = MockPeerConnectionManager()
            let client = makeSUT(signaling: sig, pcManager: pcManager)
            try await client.connect(authParams: validAuthParams)
            XCTAssertTrue(client.isConnected)
            await client.disconnect()
            XCTAssertFalse(client.isConnected)
        }
    }

    // MARK: - Concurrent Publish Operations

    func testPublishAfterDisconnectThrowsNotConnected() async throws {
        let sut = makeSUT()
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()

        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testPublishWhileICEWaiting() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.waitForIceDelayMs = 100  // Simulate slow ICE
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        // publish() should still succeed after waiting
        let stream = try await sut.publish(audio: true)
        XCTAssertTrue(stream.mediaTypes.contains(.audio))
        XCTAssertEqual(pcManager.waitForPublishIceConnectedCallCount, 1)
    }

    func testPublishWhenICETimesOut() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.shouldThrowOnWaitForIce = BandwidthRTCError.publishFailed("ICE connection timed out after 10s")
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        await XCTAssertThrowsErrorAsync(try await sut.publish()) { error in
            guard case .publishFailed = error as? BandwidthRTCError else {
                XCTFail("Expected publishFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Concurrent Media Control

    func testSetMicEnabledMultipleTimesRapidly() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        // Rapidly toggle mic on/off
        for i in 0..<10 {
            sut.setMicEnabled(i % 2 == 0)
        }

        // Last call was i=9, so enabled = false
        XCTAssertEqual(pcManager.setAudioEnabledArg, false)
        XCTAssertEqual(pcManager.setAudioEnabledCallCount, 10)
    }

    func testSendDtmfMultipleTonesRapidly() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let tones = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "*", "#"]
        for tone in tones {
            sut.sendDtmf(tone)
        }

        // Last tone should be recorded
        XCTAssertEqual(pcManager.sendDtmfArg, "#")
        XCTAssertEqual(pcManager.sendDtmfCallCount, 12)
    }

    func testMediaControlBeforeConnectDoesNotCrash() {
        let sut = makeSUT()
        // These should be safe no-ops when not connected
        sut.setMicEnabled(true)
        sut.setMicEnabled(false)
        sut.sendDtmf("1")
        // No crash = pass
    }

    // MARK: - Concurrent Callback Delivery

    func testOnStreamAvailableFromMultipleSources() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var receivedStreamIds: [String] = []
        let lock = NSLock()
        sut.onStreamAvailable = { stream in
            lock.lock()
            receivedStreamIds.append(stream.streamId)
            lock.unlock()
        }

        // Simulate multiple streams arriving
        let factory = RTCPeerConnectionFactory()
        for i in 0..<5 {
            let stream = factory.mediaStream(withStreamId: "stream-\(i)")
            pcManager.onStreamAvailable?(stream, [.audio])
        }

        // All callbacks should fire
        XCTAssertEqual(receivedStreamIds.count, 5)
    }

    func testOnStreamUnavailableCallback() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var removedIds: [String] = []
        sut.onStreamUnavailable = { id in
            removedIds.append(id)
        }

        pcManager.onStreamUnavailable?("stream-1")
        pcManager.onStreamUnavailable?("stream-2")

        XCTAssertEqual(removedIds, ["stream-1", "stream-2"])
    }

    // MARK: - Concurrent Event Handling

    func testMultipleEventsDoNotCrash() async throws {
        let sig = MockSignalingClient()
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        // Fire several events rapidly
        sig.triggerEvent("ready", data: "{}".data(using: .utf8)!)
        sig.triggerEvent("established")
        sig.triggerEvent("ready", data: "{}".data(using: .utf8)!)

        // Give events time to process
        try await Task.sleep(for: .milliseconds(50))

        // Still connected, no crash
        XCTAssertTrue(sut.isConnected)
    }

    func testCloseEventDuringActiveCallbacksDoesNotDeadlock() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(signaling: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var readyCount = 0
        sut.onReady = { _ in readyCount += 1 }

        // Fire ready then close in quick succession
        sig.triggerEvent("ready", data: "{}".data(using: .utf8)!)
        sig.triggerEvent("close")

        try await Task.sleep(for: .milliseconds(100))

        // After close, should be disconnected
        XCTAssertFalse(sut.isConnected)
    }

    // MARK: - ICE State Change Callback Safety

    func testSubscribeICEDisconnectedTriggersRemoteDisconnected() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var remoteDisconnectedCalled = false
        sut.onRemoteDisconnected = {
            remoteDisconnectedCalled = true
        }

        // Simulate subscribe ICE disconnected
        pcManager.onSubscribingIceConnectionStateChange?(.disconnected)
        XCTAssertTrue(remoteDisconnectedCalled)
    }

    func testSubscribeICEFailedTriggersRemoteDisconnected() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var remoteDisconnectedCalled = false
        sut.onRemoteDisconnected = {
            remoteDisconnectedCalled = true
        }

        // Simulate subscribe ICE failed
        pcManager.onSubscribingIceConnectionStateChange?(.failed)
        XCTAssertTrue(remoteDisconnectedCalled)
    }

    func testSubscribeICEConnectedDoesNotTriggerRemoteDisconnected() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        var remoteDisconnectedCalled = false
        sut.onRemoteDisconnected = {
            remoteDisconnectedCalled = true
        }

        pcManager.onSubscribingIceConnectionStateChange?(.connected)
        XCTAssertFalse(remoteDisconnectedCalled)
    }

    // MARK: - Thread Safety of MockSignalingClient

    func testMockSignalingClientThreadSafety() async {
        let sig = MockSignalingClient()
        // Access properties from multiple concurrent tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    if i % 2 == 0 {
                        try? await sig.connect(authParams: RtcAuthParams(endpointToken: "tok-\(i)"), options: nil)
                    } else {
                        await sig.disconnect()
                    }
                }
            }
        }
        // No crash or data race = pass
        // Connect count + disconnect count should equal 20
        XCTAssertEqual(sig.connectCalledCount + sig.disconnectCalledCount, 20)
    }

    // MARK: - Concurrent Stats Access

    func testGetCallStatsWhenNotConnected() {
        let sut = makeSUT()
        let expectation = expectation(description: "stats returned")

        sut.getCallStats(previousSnapshot: nil) { snapshot in
            // Should return empty snapshot without crash
            XCTAssertEqual(snapshot.packetsReceived, 0)
            XCTAssertEqual(snapshot.packetsSent, 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testGetCallStatsWhileConnected() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        let statsExpectation = expectation(description: "stats returned")
        sut.getCallStats(previousSnapshot: nil) { snapshot in
            // Mock returns default snapshot
            XCTAssertEqual(snapshot.packetsReceived, 0)
            statsExpectation.fulfill()
        }

        await fulfillment(of: [statsExpectation], timeout: 1.0)
    }

    // MARK: - Concurrent Outbound Connection Requests

    func testConcurrentOutboundConnectionRequests() async throws {
        let sig = MockSignalingClient()
        sig.requestOutboundResult = OutboundConnectionResult(accepted: true)
        let sut = makeSUT(signaling: sig)
        try await sut.connect(authParams: validAuthParams)

        // Fire multiple outbound connection requests concurrently
        await withTaskGroup(of: OutboundConnectionResult?.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try? await sut.requestOutboundConnection(id: "ep-\(i)", type: .endpoint)
                }
            }

            var results: [OutboundConnectionResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            XCTAssertEqual(results.count, 5)
            XCTAssertTrue(results.allSatisfy { $0.accepted })
        }

        XCTAssertEqual(sig.requestOutboundCalls.count, 5)
    }

    // MARK: - Concurrent Hangup Requests

    func testHangupWhileNotConnectedThrows() async {
        let sut = makeSUT()
        await XCTAssertThrowsErrorAsync(
            try await sut.hangupConnection(endpoint: "ep1", type: .endpoint)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }
}
