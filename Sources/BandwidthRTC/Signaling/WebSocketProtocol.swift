import Foundation

/// Protocol abstracting URLSessionWebSocketTask for testability.
protocol WebSocketProtocol: AnyObject {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)

    /// The HTTP response for the WebSocket upgrade request, once available.
    /// Used to detect a rejected handshake (e.g. 403/409) after `receive()` throws.
    var response: URLResponse? { get }
}

extension URLSessionWebSocketTask: WebSocketProtocol {}
