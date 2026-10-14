import XCTest
import WebRTC
@testable import BandwidthRTC

/// Records every SDK log line for the length of a test, so a trace's label can be asserted on.
private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    private var observerId: UUID?

    init() {
        observerId = Logger.shared.addObserver { [weak self] _, message in
            self?.lock.lock()
            self?.messages.append(message)
            self?.lock.unlock()
        }
    }

    deinit {
        if let observerId {
            Logger.shared.removeObserver(observerId)
        }
    }

    func messages(prefix: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0.hasPrefix(prefix) }
    }

    func count(prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0.hasPrefix(prefix) }.count
    }
}

/// The 10-second trace that runs while a subscribe call stream is active.
final class InCallStatsTraceTests: XCTestCase {

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")
    private let factory = RTCPeerConnectionFactory()
    private var capture: LogCapture!

    override func setUp() {
        super.setUp()
        capture = LogCapture()
    }

    override func tearDown() {
        capture = nil
        super.tearDown()
    }

    /// Both traces off by default, so a test turns on exactly the one it exercises.
    private func makeSUT(
        sig: MockSignalingClient = MockSignalingClient(),
        pcManager: MockPeerConnectionManager
    ) -> BandwidthRTCClient {
        let sut = BandwidthRTCClient(
            signaling: sig,
            peerConnectionManager: pcManager,
            audioDevice: MockMixingAudioDevice()
        )
        sut.callStatsTraceInterval = 300
        sut.inCallStatsTraceInterval = 300
        return sut
    }

    private func wait(timeout: TimeInterval = 10, for condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func startStream(_ id: String, on pcManager: MockPeerConnectionManager) {
        pcManager.onStreamAvailable?(factory.mediaStream(withStreamId: id), [.audio], nil)
    }

    private func sendSubscribeOffer(on sig: MockSignalingClient, revision: Int) {
        let json = "{\"sdpOffer\":\"v=0...\",\"peerType\":\"subscribe\",\"sdpRevision\":\(revision)}"
        sig.triggerEvent("sdpOffer", data: Data(json.utf8))
    }

    func testDoesNotTraceBeforeACallStream() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(pcManager.getCallStatsCallCount, 0)
        await sut.disconnect()
    }

    func testTracesEveryIntervalWhileACallStreamIsActive() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)

        startStream("call-1", on: pcManager)
        await wait { self.capture.count(prefix: "In-call stats:") >= 3 }

        XCTAssertGreaterThanOrEqual(capture.count(prefix: "In-call stats:"), 3)
        await sut.disconnect()
    }

    func testPassesItsOwnPreviousSnapshotToTheNextRead() async throws {
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsResult.bytesReceived = 100
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)

        startStream("call-1", on: pcManager)
        await wait { pcManager.getCallStatsCallCount >= 2 }

        XCTAssertEqual(pcManager.getCallStatsPreviousInboundBytesArgs.first, 0)
        XCTAssertEqual(pcManager.getCallStatsPreviousInboundBytesArgs[1], 100)
        await sut.disconnect()
    }

    func testReadsAFinalSnapshotAndStopsWhenTheCallEnds() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 300
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)

        pcManager.onStreamUnavailable?("call-1")
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }

        XCTAssertEqual(capture.count(prefix: "Final in-call stats (call ended):"), 1)
        XCTAssertEqual(pcManager.getCallStatsCallCount, 1)
        await sut.disconnect()
        // Nothing left to end: disconnect adds only the 5-minute trace's final read
        XCTAssertEqual(capture.count(prefix: "Final in-call stats"), 1)
        XCTAssertEqual(pcManager.getCallStatsCallCount, 2)
    }

    func testStopsTickingAfterTheCallEnds() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)
        await wait { self.capture.count(prefix: "In-call stats:") >= 1 }

        pcManager.onStreamUnavailable?("call-1")
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }
        let countAtEnd = pcManager.getCallStatsCallCount
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(pcManager.getCallStatsCallCount, countAtEnd)
        await sut.disconnect()
    }

    func testTheFirstOfTwoStreamsEndingDoesNotStopTheTraceButTheLastDoes() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)
        startStream("call-2", on: pcManager)

        pcManager.onStreamUnavailable?("call-1")
        let ticksAfterFirstEnd = capture.count(prefix: "In-call stats:")
        await wait { self.capture.count(prefix: "In-call stats:") >= ticksAfterFirstEnd + 2 }

        XCTAssertGreaterThanOrEqual(capture.count(prefix: "In-call stats:"), ticksAfterFirstEnd + 2)
        XCTAssertEqual(capture.count(prefix: "Final in-call stats"), 0)

        pcManager.onStreamUnavailable?("call-2")
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }

        XCTAssertEqual(capture.count(prefix: "Final in-call stats (call ended):"), 1)
        await sut.disconnect()
    }

    func testAnUnknownStreamEndingDoesNotStopTheTrace() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.inCallStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)

        pcManager.onStreamUnavailable?("someone-else")
        await wait { pcManager.getCallStatsCallCount >= 2 }

        XCTAssertEqual(capture.count(prefix: "Final in-call stats"), 0)
        XCTAssertGreaterThanOrEqual(pcManager.getCallStatsCallCount, 2)
        await sut.disconnect()
    }

    func testReadsAFinalSnapshotOnDisconnectBeforeTheMediaIsReleased() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)

        await sut.disconnect()

        XCTAssertEqual(capture.count(prefix: "Final in-call stats (session cleanup):"), 1)
        // The 5-minute trace's own final read comes first; this is the in-call one after it
        XCTAssertEqual(pcManager.getCallStatsCleanupCallCountArgs, [0, 0])
        XCTAssertEqual(pcManager.cleanupCallCount, 1)
    }

    func testReadsAFinalSnapshotWhenTheSocketClosesDuringACall() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(sig: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)

        sig.triggerEvent("close")
        await wait { self.capture.count(prefix: "Final in-call stats (session cleanup):") >= 1 }

        XCTAssertEqual(capture.count(prefix: "Final in-call stats (session cleanup):"), 1)
        XCTAssertEqual(pcManager.getCallStatsCleanupCallCountArgs.last, 0)
    }

    func testReadsNoFinalSnapshotWhenNoCallWasActive() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        await sut.disconnect()

        XCTAssertEqual(capture.count(prefix: "Final in-call stats"), 0)
    }

    func testEndsTheTraceBeforeAReconnectResetsThePeerConnectionsAndRestartsWithTheNextStream() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(sig: sig, pcManager: pcManager)
        sut.reconnectBaseDelay = 0.02
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)

        let retryableClose = (try? JSONEncoder().encode(WebSocketCloseInfo(closeCode: 1001))) ?? Data()
        sig.triggerEvent("close", data: retryableClose)
        // The injected manager is reset on the first connect too, so the reconnect is the second reset
        await wait { pcManager.resetPeerConnectionsCallCount >= 2 }

        XCTAssertEqual(capture.count(prefix: "Final in-call stats (reconnect):"), 1)
        // One read for each trace's final snapshot, both before the reset
        XCTAssertEqual(pcManager.getCallStatsResetCallCountArgs, [1, 1])

        // The old streams never fire unavailable; the new session's track starts the trace again
        sut.inCallStatsTraceInterval = 0.05
        startStream("call-2", on: pcManager)
        await wait { self.capture.count(prefix: "In-call stats:") >= 2 }

        XCTAssertGreaterThanOrEqual(capture.count(prefix: "In-call stats:"), 2)
        await sut.disconnect()
    }

    func testTheFiveMinuteTraceKeepsRunningThroughACall() async throws {
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(pcManager: pcManager)
        sut.callStatsTraceInterval = 0.05
        try await sut.connect(authParams: validAuthParams)

        startStream("call-1", on: pcManager)
        pcManager.onStreamUnavailable?("call-1")
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }
        let ticksAtCallEnd = capture.count(prefix: "Call stats:")
        await wait { self.capture.count(prefix: "Call stats:") >= ticksAtCallEnd + 2 }

        XCTAssertGreaterThanOrEqual(capture.count(prefix: "Call stats:"), ticksAtCallEnd + 2)
        XCTAssertEqual(capture.count(prefix: "In-call stats:"), 0)
        XCTAssertEqual(capture.count(prefix: "Final call stats"), 0)
        await sut.disconnect()
    }

    // MARK: - Final snapshot taken before the ending re-offer

    func testFinalSnapshotCarriesTheCountersReadBeforeTheEndingReOffer() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsResult.bytesReceived = 4242
        let sut = makeSUT(sig: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)
        // The re-offer removes the track: its stats are gone by the time the stream is unavailable
        pcManager.onHandleSubscribeSdpOffer = {
            pcManager.getCallStatsResult = CallStatsSnapshot()
            pcManager.onStreamUnavailable?("call-1")
        }

        sendSubscribeOffer(on: sig, revision: 1)
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }

        let finals = capture.messages(prefix: "Final in-call stats (call ended):")
        XCTAssertEqual(finals.count, 1)
        XCTAssertTrue(finals[0].contains("bytesReceived: 4242"), finals[0])
        // The one read happened before the offer was applied, and the call end did not read again
        XCTAssertEqual(pcManager.handleSubscribeSdpOfferGetCallStatsCallCountArgs, [1])
        XCTAssertEqual(pcManager.getCallStatsCallCount, 1)
        await sut.disconnect()
    }

    func testReadsNothingBeforeASubscribeOfferWhenNoCallStreamIsActive() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        let sut = makeSUT(sig: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)

        sendSubscribeOffer(on: sig, revision: 1)
        await wait { pcManager.handleSubscribeSdpOfferCallCount >= 1 }

        XCTAssertEqual(pcManager.handleSubscribeSdpOfferCallCount, 1)
        XCTAssertEqual(pcManager.getCallStatsCallCount, 0)

        // Nothing was stashed, so the call end falls back to a fresh read
        pcManager.getCallStatsResult.bytesReceived = 7
        startStream("call-1", on: pcManager)
        pcManager.onStreamUnavailable?("call-1")
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }

        let finals = capture.messages(prefix: "Final in-call stats (call ended):")
        XCTAssertEqual(finals.count, 1)
        XCTAssertTrue(finals[0].contains("bytesReceived: 7"), finals[0])
        XCTAssertEqual(pcManager.getCallStatsCallCount, 1)
        await sut.disconnect()
    }

    func testTheStashedSnapshotIsNotReusedByTheNextCall() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsResult.bytesReceived = 4242
        let sut = makeSUT(sig: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)
        pcManager.onHandleSubscribeSdpOffer = { pcManager.onStreamUnavailable?("call-1") }
        sendSubscribeOffer(on: sig, revision: 1)
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 1 }
        pcManager.onHandleSubscribeSdpOffer = nil

        // The second call ends without a re-offer, so no snapshot was stashed for it
        pcManager.getCallStatsResult.bytesReceived = 99
        startStream("call-2", on: pcManager)
        pcManager.onStreamUnavailable?("call-2")
        await wait { self.capture.count(prefix: "Final in-call stats (call ended):") >= 2 }

        let finals = capture.messages(prefix: "Final in-call stats (call ended):")
        XCTAssertEqual(finals.count, 2)
        XCTAssertTrue(finals[0].contains("bytesReceived: 4242"), finals[0])
        XCTAssertTrue(finals[1].contains("bytesReceived: 99"), finals[1])
        await sut.disconnect()
    }

    func testTeardownStillReadsAFreshSnapshotAfterAnOfferThatDidNotEndTheCall() async throws {
        let sig = MockSignalingClient()
        let pcManager = MockPeerConnectionManager()
        pcManager.getCallStatsResult.bytesReceived = 4242
        let sut = makeSUT(sig: sig, pcManager: pcManager)
        try await sut.connect(authParams: validAuthParams)
        startStream("call-1", on: pcManager)
        sendSubscribeOffer(on: sig, revision: 1)
        await wait { pcManager.getCallStatsCallCount >= 1 }

        pcManager.getCallStatsResult.bytesReceived = 99
        await sut.disconnect()

        let finals = capture.messages(prefix: "Final in-call stats (session cleanup):")
        XCTAssertEqual(finals.count, 1)
        XCTAssertTrue(finals[0].contains("bytesReceived: 99"), finals[0])
        // Still before the media was released
        XCTAssertEqual(pcManager.getCallStatsCleanupCallCountArgs.last, 0)
    }
}
