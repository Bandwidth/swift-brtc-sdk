import Foundation

/// Default BRTC WebSocket gateway URL.
private let defaultGatewayURL = "wss://gateway.pv.prod.global.aws.bandwidth.com/prod/gateway-service/api/v1/endpoints"

/// SDK version reported to the gateway.
private let sdkVersion = SDKVersion.current

/// Ping interval in seconds.
private let pingInterval: TimeInterval = 60

/// Actor that manages the WebSocket connection and JSON-RPC signaling with the BRTC gateway.
actor SignalingClient {
    private let log = Logger.shared

    /// Factory that creates a WebSocket connection for a given URL and returns the socket plus
    /// an optional URLSession to invalidate on disconnect.
    private let webSocketFactory: (URL) -> (any WebSocketProtocol, URLSession?)

    // WebSocket state
    private var webSocket: (any WebSocketProtocol)?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    // JSON-RPC request/response correlation
    private var pendingRequests: [String: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var nextRequestId: Int = 1

    // Event handlers for server notifications (sdpOffer, ready, established, etc.)
    private var eventHandlers: [String: @Sendable (Data) -> Void] = [:]

    // Connection state
    private(set) var isConnected = false

    // MARK: - Init

    init(webSocketFactory: @escaping (URL) -> (any WebSocketProtocol, URLSession?) = { url in
        let session = URLSession(configuration: .default)
        return (session.webSocketTask(with: url), session)
    }) {
        self.webSocketFactory = webSocketFactory
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
    }

    // MARK: - Connection

    func connect(authParams: RtcAuthParams, options: RtcOptions?) async throws {
        guard !isConnected else { throw BandwidthRTCError.alreadyConnected }

        let baseURL = options?.websocketUrl ?? defaultGatewayURL
        let uniqueId = UUID().uuidString

        guard var components = URLComponents(string: baseURL),
              components.scheme != nil,
              components.host != nil else {
            throw BandwidthRTCError.connectionFailed("Invalid gateway URL")
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "ios"),
            URLQueryItem(name: "sdkVersion", value: sdkVersion),
            URLQueryItem(name: "uniqueId", value: uniqueId),
            URLQueryItem(name: "endpointToken", value: authParams.endpointToken),
        ]

        guard let url = components.url else {
            throw BandwidthRTCError.connectionFailed("Invalid gateway URL")
        }

        log.debug("Gateway URL: \(url)")
        log.info("Connecting to \(url.host ?? "unknown")")

        let (ws, session) = webSocketFactory(url)
        ws.resume()

        self.urlSession = session
        self.webSocket = ws
        self.isConnected = true

        // Start receiving messages
        startReceiveLoop()

        // Start ping keepalive
        startPingLoop()

        log.debug("WebSocket connection initiated")
    }

    func disconnect() async {
        log.info("Disconnecting")

        // Send leave notification (fire-and-forget)
        sendNotification(method: "leave", params: EmptyParams())
        log.debug("Leave notification sent")

        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false

        // Fail any pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: BandwidthRTCError.webSocketDisconnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Event Handlers

    func onEvent(_ method: String, handler: @escaping @Sendable (Data) -> Void) async {
        eventHandlers[method] = handler
    }

    func removeEventHandler(_ method: String) async {
        eventHandlers.removeValue(forKey: method)
    }

    // MARK: - RPC Methods

    func setMediaPreferences() async throws -> SetMediaPreferencesResult {
        let result = try await call(method: "setMediaPreferences", params: SetMediaPreferencesParams())
        guard let result else {
            return SetMediaPreferencesResult(endpointId: nil, deviceId: nil, publishSdpOffer: nil, subscribeSdpOffer: nil)
        }
        return try result.decode(SetMediaPreferencesResult.self)
    }

    func offerSdp(sdpOffer: String, peerType: String) async throws -> OfferSdpResult {
        let params = OfferSdpParams(sdpOffer: sdpOffer, peerType: peerType)
        let result = try await call(method: "offerSdp", params: params)
        guard let result else {
            throw BandwidthRTCError.sdpNegotiationFailed("No result from offerSdp")
        }
        return try result.decode(OfferSdpResult.self)
    }

    func answerSdp(sdpAnswer: String, peerType: String) async throws {
        let params = AnswerSdpParams(peerType: peerType, sdpAnswer: sdpAnswer)
        _ = try await call(method: "answerSdp", params: params)
    }

    func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult {
        let params = RequestOutboundConnectionParams(id: id, type: type)
        let result = try await call(method: "requestOutboundConnection", params: params)
        guard let result else {
            return OutboundConnectionResult(accepted: false)
        }
        return try result.decode(OutboundConnectionResult.self)
    }

    func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult {
        let params = HangupConnectionParams(endpoint: endpoint, type: type)
        let result = try await call(method: "hangupConnection", params: params)
        guard let result else {
            return HangupResult(result: nil)
        }
        // When hanging up a ringing call, the server may return a bare string
        // (e.g. "bye") instead of an object like {"result": "bye"}.
        if let stringResult = result.value as? String {
            return HangupResult(result: stringResult)
        }
        return try result.decode(HangupResult.self)
    }

    // MARK: - Private: JSON-RPC Call/Notify

    private func call<P: Encodable>(method: String, params: P) async throws -> AnyCodable? {
        guard let webSocket, isConnected else {
            throw BandwidthRTCError.notConnected
        }

        let id = generateRequestId()
        let request = JsonRpcRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let message = String(data: data, encoding: .utf8)!

        log.debug("RPC call: \(method) id=\(id)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            webSocket.send(.string(message)) { [weak self] error in
                if let error {
                    Task { [weak self] in
                        await self?.failPendingRequest(id: id, error: error)
                    }
                }
            }
        }
    }

    private func sendNotification<P: Encodable>(method: String, params: P) {
        guard let webSocket, isConnected else { return }

        let notification = JsonRpcNotification(method: method, params: params)
        guard let data = try? JSONEncoder().encode(notification),
              let message = String(data: data, encoding: .utf8) else { return }

        log.debug("RPC notify: \(method)")
        webSocket.send(.string(message)) { _ in }
    }

    private func generateRequestId() -> String {
        let id = nextRequestId
        nextRequestId += 1
        return String(id)
    }

    private func failPendingRequest(id: String, error: Error) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Private: WebSocket Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let ws = await self.webSocket else { break }
                    let message = try await ws.receive()
                    await self.handleMessage(message)
                } catch {
                    await self.handleReceiveError(error)
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else { return }
            data = textData
        case .data(let binaryData):
            log.debug("Received binary WebSocket message (\(binaryData.count) bytes)")
            data = binaryData
        @unknown default:
            return
        }

        let rawString = String(data: data, encoding: .utf8) ?? "?"
        log.debug("WS received: \(String(rawString.prefix(200)))")

        guard let incoming = try? JSONDecoder().decode(JsonRpcIncoming.self, from: data) else {
            log.warn("Failed to decode incoming JSON-RPC message")
            return
        }

        if incoming.isResponse {
            handleResponse(incoming)
        } else if incoming.isNotification {
            handleNotification(incoming, rawData: data)
        }
    }

    private func handleResponse(_ response: JsonRpcIncoming) {
        guard let id = response.id else { return }

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            log.warn("Received response for unknown request id=\(id)")
            return
        }

        if let error = response.error {
            log.error("RPC error id=\(id): \(error.message)")
            if error.code == 403 || error.message.lowercased().contains("invalid token") {
                continuation.resume(throwing: BandwidthRTCError.invalidToken)
            } else {
                continuation.resume(throwing: BandwidthRTCError.rpcError(code: error.code, message: error.message))
            }
        } else {
            log.debug("RPC response id=\(id)")
            continuation.resume(returning: response.result)
        }
    }

    private func handleNotification(_ notification: JsonRpcIncoming, rawData: Data) {
        guard let method = notification.method else { return }
        log.debug("Server notification: \(method)")

        // Extract the params portion and re-encode for the handler
        if let handler = eventHandlers[method] {
            if let params = notification.params {
                if let paramsData = try? JSONSerialization.data(withJSONObject: params.value) {
                    handler(paramsData)
                } else {
                    log.warn("Failed to re-encode params for \(method)")
                    handler(Data())
                }
            } else {
                log.debug("Notification \(method) has no params")
                handler(Data())
            }
        } else {
            log.warn("No handler registered for notification: \(method)")
        }
    }

    private func handleReceiveError(_ error: Error) {
        log.error("WebSocket receive error: \(error.localizedDescription)")
        let wasConnected = isConnected
        isConnected = false

        // Fail all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: BandwidthRTCError.webSocketDisconnected)
        }
        pendingRequests.removeAll()

        if wasConnected {
            // Notify disconnect handler
            if let handler = eventHandlers["close"] {
                handler(Data())
            }
        }
    }

    // MARK: - Private: Ping Keepalive

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { break }
                await self.sendPing()
            }
        }
    }

    private func sendPing() {
        sendNotification(method: "ping", params: EmptyParams())
        log.debug("Ping sent")
    }
}
