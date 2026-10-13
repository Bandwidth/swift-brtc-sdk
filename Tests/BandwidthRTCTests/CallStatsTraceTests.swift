import XCTest
@testable import BandwidthRTC

/// The periodic call stats trace that runs while a session is connected.
final class CallStatsTraceTests: XCTestCase {

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")

    private func makeSUT(pcManager: MockPeerConnectionManager) -> BandwidthRTCClient {
        let sut = BandwidthRTCClient(
            signaling: MockSignalingClient(),
            peerConnectionManager: pcManager,
            audioDevice: MockMixingAudioDevice()
        )
        sut.callStatsTraceInterval = 0.05
        return sut
    }

    private func wait(timeout: TimeInterval = 10, for condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCollectsStatsPeriodicallyWhileConnected() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)

        try await sut.connect(authParams: validAuthParams)
        await wait { pcManager.getCallStatsCallCount >= 2 }

        XCTAssertGreaterThanOrEqual(pcManager.getCallStatsCallCount, 2)
        await sut.disconnect()
    }

    func testPassesPreviousTracedSnapshotToNextCollection() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsResult.bytesReceived = 100
        let sut = makeSUT(pcManager: pcManager)

        try await sut.connect(authParams: validAuthParams)
        await wait { pcManager.getCallStatsCallCount >= 2 }

        XCTAssertEqual(pcManager.getCallStatsPreviousInboundBytesArgs.first, 0)
        XCTAssertEqual(pcManager.getCallStatsPreviousInboundBytesArgs[1], 100)
        await sut.disconnect()
    }

    func testDoesNotCollectStatsBeforeFirstInterval() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.callStatsTraceInterval = 300

        try await sut.connect(authParams: validAuthParams)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(pcManager.getCallStatsCallCount, 0)
        await sut.disconnect()
    }

    func testStopsCollectingAfterDisconnect() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        await sut.disconnect()
        let countAtDisconnect = pcManager.getCallStatsCallCount

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(pcManager.getCallStatsCallCount, countAtDisconnect)
    }

    func testReadsAFinalSnapshotOnDisconnectBeforeTheMediaIsReleased() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.callStatsTraceInterval = 300
        try await sut.connect(authParams: validAuthParams)

        await sut.disconnect()

        XCTAssertEqual(pcManager.getCallStatsCallCount, 1)
        XCTAssertEqual(pcManager.getCallStatsCleanupCallCountArgs, [0])
        XCTAssertEqual(pcManager.cleanupCallCount, 1)
    }

    func testFinalSnapshotCarriesTheLastTracedSnapshotAsBaseline() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsResult.bytesReceived = 100
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        await wait { pcManager.getCallStatsCallCount >= 1 }

        await sut.disconnect()

        XCTAssertEqual(pcManager.getCallStatsPreviousInboundBytesArgs.last, 100)
    }

    func testReadsAFinalSnapshotWhenTheSocketClosesWithoutDisconnect() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = BandwidthRTCClient(
            signaling: sig,
            peerConnectionManager: pcManager,
            audioDevice: MockMixingAudioDevice()
        )
        sut.callStatsTraceInterval = 300
        try await sut.connect(authParams: validAuthParams)

        sig.triggerEvent("close")
        await wait { pcManager.getCallStatsCallCount >= 1 }

        XCTAssertEqual(pcManager.getCallStatsCallCount, 1)
        XCTAssertEqual(pcManager.getCallStatsCleanupCallCountArgs, [0])
    }

    func testReadsTheFinalSnapshotOnceWhenDisconnectFollowsASocketClose() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = BandwidthRTCClient(
            signaling: sig,
            peerConnectionManager: pcManager,
            audioDevice: MockMixingAudioDevice()
        )
        sut.callStatsTraceInterval = 300
        try await sut.connect(authParams: validAuthParams)

        sig.triggerEvent("close")
        await wait { pcManager.getCallStatsCallCount >= 1 }
        await sut.disconnect()

        XCTAssertEqual(pcManager.getCallStatsCallCount, 1)
    }

    func testReadsNoFinalSnapshotWhenNoTraceStarted() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)

        await sut.disconnect()

        XCTAssertEqual(pcManager.getCallStatsCallCount, 0)
    }

    func testAReadThatNeverCompletesDoesNotStallDisconnectOrBecomeABaseline() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsCompletes = false
        pcManager.getCallStatsResult.bytesReceived = 100
        let sut = makeSUT(pcManager: pcManager)
        sut.callStatsReadTimeout = 0.05
        try await sut.connect(authParams: validAuthParams)
        await wait { pcManager.getCallStatsCallCount >= 2 }

        await sut.disconnect()

        // No read completed, so none was passed on as a baseline
        XCTAssertTrue(pcManager.getCallStatsPreviousInboundBytesArgs.allSatisfy { $0 == 0 })
        XCTAssertEqual(pcManager.cleanupCallCount, 1)
    }

    func testReadsAFinalSnapshotOfTheOldSessionBeforeAReconnectResetsThePeerConnections() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = BandwidthRTCClient(
            signaling: sig,
            peerConnectionManager: pcManager,
            audioDevice: MockMixingAudioDevice()
        )
        sut.callStatsTraceInterval = 300
        sut.reconnectBaseDelay = 0.02
        try await sut.connect(authParams: validAuthParams)

        let retryableClose = (try? JSONEncoder().encode(WebSocketCloseInfo(closeCode: 1001))) ?? Data()
        sig.triggerEvent("close", data: retryableClose)
        // The injected manager is reset on the first connect too, so the reconnect is the second reset
        await wait { pcManager.resetPeerConnectionsCallCount >= 2 }

        XCTAssertEqual(pcManager.getCallStatsResetCallCountArgs, [1])
        await sut.disconnect()
    }
}
