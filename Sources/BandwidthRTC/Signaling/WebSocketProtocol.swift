import Foundation

/// Protocol abstracting URLSessionWebSocketTask for testability.
protocol WebSocketProtocol: AnyObject {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: WebSocketProtocol {}
