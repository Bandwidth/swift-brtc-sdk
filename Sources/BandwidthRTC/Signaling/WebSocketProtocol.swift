import Foundation

/// Protocol abstracting URLSessionWebSocketTask for testability.
protocol WebSocketProtocol: AnyObject {
    /// The server's response to the upgrade request. Carries the HTTP status code when the
    /// gateway rejects the handshake outright (e.g. 403 invalid token, 409 already connected).
    var response: URLResponse? { get }
    /// The close code from the WebSocket close frame, once the connection has closed. `.invalid`
    /// (the default) means no close frame was ever received - e.g. the connection dropped
    /// abnormally (network loss) rather than being closed deliberately by either side.
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: WebSocketProtocol {}
