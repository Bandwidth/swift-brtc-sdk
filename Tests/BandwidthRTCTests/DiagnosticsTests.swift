import XCTest
@testable import BandwidthRTC

/// Client logs shipped to the gateway as `deviceDiagnostics`.
final class DiagnosticsTests: XCTestCase {

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token")
    private var originalLevel: LogLevel = .warn

    override func setUp() {
        super.setUp()
        originalLevel = Logger.shared.level
    }

    override func tearDown() {
        Logger.shared.level = originalLevel
        super.tearDown()
    }

    private func wait(timeout: TimeInterval = 10, for condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Decoded `params` of every deviceDiagnostics notification sent on the socket so far.
    private func diagnosticsParams(from ws: MockWebSocket) -> [[String: Any]] {
        ws.sentStrings().compactMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["method"] as? String == "deviceDiagnostics",
                  let params = object["params"] as? [String: Any] else { return nil }
            return params
        }
    }

    private func loggedMessages(in params: [[String: Any]]) -> [String] {
        params.flatMap { ($0["logs"] as? [[String: Any]]) ?? [] }
            .flatMap { ($0["message"] as? [String]) ?? [] }
    }

    // MARK: - DiagnosticsBatcher

    func testCapturesEveryLevelRegardlessOfTheConfiguredLogLevel() {
        Logger.shared.level = .off
        let batcher = DiagnosticsBatcher()
        batcher.start()
        defer { batcher.stop() }

        Logger.shared.error("diag-test error")
        Logger.shared.warn("diag-test warn")
        Logger.shared.info("diag-test info")
        Logger.shared.debug("diag-test debug")
        Logger.shared.trace("diag-test trace")
        let entries = batcher.drain().filter { $0.message[0].hasPrefix("diag-test") }

        XCTAssertEqual(entries.map(\.level), ["error", "warn", "info", "debug", "trace"])
        XCTAssertEqual(entries.map(\.message), [
            ["diag-test error"], ["diag-test warn"], ["diag-test info"], ["diag-test debug"], ["diag-test trace"],
        ])
    }

    func testStampsEntriesWithEpochMilliseconds() {
        let batcher = DiagnosticsBatcher()
        let before = Int64(Date().timeIntervalSince1970 * 1000)

        batcher.record(level: .info, message: "stamped")
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        let timestamp = batcher.drain()[0].timestamp
        XCTAssertTrue((before...after).contains(timestamp))
    }

    func testStopsCapturingAfterStop() {
        let batcher = DiagnosticsBatcher()
        batcher.start()
        batcher.stop()

        Logger.shared.error("diag-test after stop")

        XCTAssertFalse(batcher.drain().contains { $0.message[0] == "diag-test after stop" })
    }

    func testDrainEmptiesTheBuffer() {
        let batcher = DiagnosticsBatcher()
        batcher.record(level: .info, message: "one")

        XCTAssertEqual(batcher.drain().count, 1)
        XCTAssertTrue(batcher.drain().isEmpty)
    }

    func testCapDropsTheOldestEntries() {
        let batcher = DiagnosticsBatcher(maxEntries: 3)

        for i in 0..<20 {
            batcher.record(level: .info, message: "entry-\(i)")
        }

        XCTAssertEqual(batcher.drain().map { $0.message[0] }, ["entry-17", "entry-18", "entry-19"])
    }

    func testCapKeepsHoldingAcrossDrains() {
        let batcher = DiagnosticsBatcher(maxEntries: 3)
        for i in 0..<10 {
            batcher.record(level: .info, message: "old-\(i)")
        }
        _ = batcher.drain()

        for i in 0..<4 {
            batcher.record(level: .info, message: "new-\(i)")
        }

        XCTAssertEqual(batcher.drain().map { $0.message[0] }, ["new-1", "new-2", "new-3"])
    }

    // MARK: - SignalingClient flush

    func testFlushSendsADeviceDiagnosticsNotificationWithTheGatewayShape() async throws {
        let ws = MockWebSocket()
        let sut = SignalingClient(webSocketFactory: { _ in (ws, nil) }, diagnosticsFlushInterval: 0.05)
        try await sut.connect(authParams: validAuthParams, options: nil)

        await wait { !self.diagnosticsParams(from: ws).isEmpty }
        await sut.disconnect()

        let raw = ws.sentStrings().first { $0.contains("deviceDiagnostics") }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(raw).utf8)) as? [String: Any])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["method"] as? String, "deviceDiagnostics")
        XCTAssertNil(object["id"], "a notification carries no id")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let logs = try XCTUnwrap(params["logs"] as? [[String: Any]])
        XCTAssertFalse(logs.isEmpty)
        for entry in logs {
            XCTAssertTrue(entry["level"] is String)
            XCTAssertTrue(entry["timestamp"] is NSNumber)
            XCTAssertTrue(entry["message"] is [String])
        }
    }

    func testFlushSendsTheBufferedLogsOnlyOnce() async throws {
        let ws = MockWebSocket()
        let sut = SignalingClient(webSocketFactory: { _ in (ws, nil) }, diagnosticsFlushInterval: 0.05)
        try await sut.connect(authParams: validAuthParams, options: nil)
        Logger.shared.warn("diag-test once")

        await wait { self.loggedMessages(in: self.diagnosticsParams(from: ws)).contains("diag-test once") }
        try await Task.sleep(nanoseconds: 200_000_000)
        await sut.disconnect()

        let sent = loggedMessages(in: diagnosticsParams(from: ws)).filter { $0 == "diag-test once" }
        XCTAssertEqual(sent.count, 1)
    }

    func testAnEmptyBatchIsNotSent() async throws {
        let ws = MockWebSocket()
        let batcher = DiagnosticsBatcher()
        let sut = SignalingClient(webSocketFactory: { _ in (ws, nil) }, diagnosticsFlushInterval: 0.05, diagnostics: batcher)
        try await sut.connect(authParams: validAuthParams, options: nil)
        // Nothing is captured from here on, so every flush finds an empty buffer
        batcher.stop()
        batcher.discard()

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(diagnosticsParams(from: ws).isEmpty)
        await sut.disconnect()
    }

    func testDisconnectSendsTheFinalBatchBeforeTheSocketCloses() async throws {
        let ws = MockWebSocket()
        let sut = SignalingClient(webSocketFactory: { _ in (ws, nil) }, diagnosticsFlushInterval: 300)
        try await sut.connect(authParams: validAuthParams, options: nil)

        await sut.disconnect()

        let params = diagnosticsParams(from: ws)
        XCTAssertEqual(params.count, 1)
        XCTAssertTrue(loggedMessages(in: params).contains("Disconnecting"))
        XCTAssertTrue(ws.cancelCalled)
        // Leave, then the final batch, then the close
        XCTAssertEqual(ws.sentCountAtCancel, 2)
        XCTAssertTrue(ws.sentStrings().last?.contains("deviceDiagnostics") == true)
    }

    func testNothingIsSentAfterDisconnect() async throws {
        let ws = MockWebSocket()
        let sut = SignalingClient(webSocketFactory: { _ in (ws, nil) }, diagnosticsFlushInterval: 0.05)
        try await sut.connect(authParams: validAuthParams, options: nil)
        await sut.disconnect()
        let sentAtDisconnect = ws.sentStrings().count

        Logger.shared.warn("diag-test after disconnect")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(ws.sentStrings().count, sentAtDisconnect)
    }

    func testAFailedSendIsLoggedAndDoesNotTriggerAnotherSend() async throws {
        let ws = MockWebSocket()
        ws.sendError = URLError(.networkConnectionLost)
        let batcher = DiagnosticsBatcher()
        let sut = SignalingClient(webSocketFactory: { _ in (ws, nil) }, diagnosticsFlushInterval: 300, diagnostics: batcher)
        try await sut.connect(authParams: validAuthParams, options: nil)
        let errors = ErrorLogCapture()

        await sut.disconnect()

        XCTAssertEqual(errors.count(containing: "Error sending diagnostics"), 1)
        // The one final batch; the error it logged did not cause a second send
        XCTAssertEqual(ws.sentStrings().filter { $0.contains("deviceDiagnostics") }.count, 1)
    }
}

/// Records SDK error-level log lines.
private final class ErrorLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    private var observerId: UUID?

    init() {
        observerId = Logger.shared.addObserver { [weak self] level, message in
            guard level == .error else { return }
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

    func count(containing text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0.contains(text) }.count
    }
}
