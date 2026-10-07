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
}
