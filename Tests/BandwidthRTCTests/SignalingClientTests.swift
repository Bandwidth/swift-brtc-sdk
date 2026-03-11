import XCTest
@testable import BandwidthRTC

final class SignalingClientTests: XCTestCase {

    private let validAuthParams = RtcAuthParams(endpointToken: "test-token-abc")

    // MARK: - Connection — URL Building

    func testConnectBuildsCorrectURL() async throws {
        var capturedURL: URL?
        let mockWS = MockWebSocket()
        let sut = SignalingClient { url in
            capturedURL = url
            return (mockWS, nil)
        }

        // connect() will block on the receive loop; cancel the task after triggering the URL capture
        let task = Task {
            try await sut.connect(authParams: self.validAuthParams, options: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        guard let url = capturedURL else {
            XCTFail("webSocketFactory was not called")
            return
        }

        let query = url.query ?? ""
        XCTAssertTrue(query.contains("endpointToken=test-token-abc"), "Query missing endpointToken: \(query)")
        XCTAssertTrue(query.contains("client=ios"), "Query missing client=ios: \(query)")
        XCTAssertTrue(query.contains("sdkVersion="), "Query missing sdkVersion: \(query)")
    }

    func testConnectSetsIsConnected() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let task = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let connected = await sut.isConnected
        XCTAssertTrue(connected)
    }

    func testConnectThrowsIfAlreadyConnected() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        // First connect
        let task = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        // Second connect — should throw
        await XCTAssertThrowsErrorAsync(
            try await sut.connect(authParams: self.validAuthParams, options: nil)
        ) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .alreadyConnected)
        }
    }

    func testConnectThrowsOnInvalidGatewayURL() async {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let badOptions = RtcOptions(websocketUrl: ":::invalid:::")
        await XCTAssertThrowsErrorAsync(
            try await sut.connect(authParams: self.validAuthParams, options: badOptions)
        ) { error in
            guard case .connectionFailed = error as? BandwidthRTCError else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Disconnect

    func testDisconnectSetsNotConnected() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let task = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await sut.disconnect()
        let connected = await sut.isConnected
        XCTAssertFalse(connected)
    }

    func testDisconnectFailsPendingRequests() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        // Connect
        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        // Start an RPC call that will block waiting for a response
        let rpcTask = Task<SetMediaPreferencesResult?, Never> {
            try? await sut.setMediaPreferences()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Disconnect should fail pending requests
        await sut.disconnect()
        let result = await rpcTask.value
        // result is nil because the continuation threw
        XCTAssertNil(result)
    }

    // MARK: - RPC Error Routing

    func testRpcErrorCode403ThrowsInvalidToken() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        // Launch RPC call
        let rpcTask = Task {
            try await sut.setMediaPreferences()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Deliver a 403 error response for request id "1"
        let errorJson = """
        {"jsonrpc":"2.0","id":"1","error":{"code":403,"message":"Unauthorized"}}
        """.data(using: .utf8)!
        mockWS.enqueue(.data(errorJson))

        await XCTAssertThrowsErrorAsync(try await rpcTask.value) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .invalidToken)
        }
    }

    func testRpcErrorWithInvalidTokenMessageThrowsInvalidToken() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        let rpcTask = Task { try await sut.setMediaPreferences() }
        try await Task.sleep(for: .milliseconds(20))

        let errorJson = """
        {"jsonrpc":"2.0","id":"1","error":{"code":401,"message":"invalid token provided"}}
        """.data(using: .utf8)!
        mockWS.enqueue(.data(errorJson))

        await XCTAssertThrowsErrorAsync(try await rpcTask.value) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .invalidToken)
        }
    }

    func testRpcGenericErrorThrowsRpcError() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        let rpcTask = Task { try await sut.setMediaPreferences() }
        try await Task.sleep(for: .milliseconds(20))

        let errorJson = """
        {"jsonrpc":"2.0","id":"1","error":{"code":500,"message":"Internal server error"}}
        """.data(using: .utf8)!
        mockWS.enqueue(.data(errorJson))

        await XCTAssertThrowsErrorAsync(try await rpcTask.value) { error in
            guard case .rpcError(let code, let message) = error as? BandwidthRTCError else {
                XCTFail("Expected rpcError")
                return
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "Internal server error")
        }
    }

    func testCallThrowsWhenNotConnected() async {
        let sut = SignalingClient { _ in (MockWebSocket(), nil) }
        await XCTAssertThrowsErrorAsync(try await sut.setMediaPreferences()) { error in
            XCTAssertEqual(error as? BandwidthRTCError, .notConnected)
        }
    }

    func testUnknownRequestIdIgnored() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        // Response for unknown request id — should not crash
        let unknownResponse = """
        {"jsonrpc":"2.0","id":"999","result":{}}
        """.data(using: .utf8)!
        mockWS.enqueue(.string(String(data: unknownResponse, encoding: .utf8)!))
        try await Task.sleep(for: .milliseconds(50))
        // No crash = pass
    }

    // MARK: - Event Handling

    func testOnEventHandlerCalledForNotification() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        var receivedData: Data?
        await sut.onEvent("ready") { data in receivedData = data }

        let notification = """
        {"jsonrpc":"2.0","method":"ready","params":{"endpointId":"ep-1"}}
        """.data(using: .utf8)!
        mockWS.enqueue(.string(String(data: notification, encoding: .utf8)!))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(receivedData)
    }

    func testRemoveEventHandlerPreventsCallback() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        var callCount = 0
        await sut.onEvent("ready") { _ in callCount += 1 }
        await sut.removeEventHandler("ready")

        let notification = """
        {"jsonrpc":"2.0","method":"ready","params":{}}
        """.data(using: .utf8)!
        mockWS.enqueue(.string(String(data: notification, encoding: .utf8)!))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(callCount, 0)
    }

    func testCloseEventOnReceiveError() async throws {
        let mockWS = MockWebSocket()
        let sut = SignalingClient { _ in (mockWS, nil) }

        let connectTask = Task { try await sut.connect(authParams: self.validAuthParams, options: nil) }
        try await Task.sleep(for: .milliseconds(50))
        connectTask.cancel()

        let closeExpectation = expectation(description: "close event fired")
        await sut.onEvent("close") { _ in closeExpectation.fulfill() }

        // Inject a receive error to simulate WebSocket drop
        mockWS.enqueueError(URLError(.networkConnectionLost))
        await fulfillment(of: [closeExpectation], timeout: 2.0)

        let connected = await sut.isConnected
        XCTAssertFalse(connected)
    }
}
