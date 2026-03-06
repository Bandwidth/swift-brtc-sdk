import Foundation
@testable import BandwidthBRTC

/// Mock WebSocket for testing SignalingClient without real network connections.
/// Uses @unchecked Sendable + NSLock for thread safety since WebSocketProtocol
/// requires synchronous send/resume/cancel that must be callable from actor contexts.
final class MockWebSocket: @unchecked Sendable, WebSocketProtocol {

    private let lock = NSLock()
    private var messageQueue: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var pendingContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    // MARK: - Captured calls

    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var resumeCallCount: Int = 0
    private(set) var cancelCalled: Bool = false
    private(set) var capturedCancelCode: URLSessionWebSocketTask.CloseCode?

    // MARK: - WebSocketProtocol

    func resume() {
        lock.lock()
        resumeCallCount += 1
        lock.unlock()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelCalled = true
        capturedCancelCode = closeCode
        let cont = pendingContinuation
        pendingContinuation = nil
        lock.unlock()
        cont?.resume(throwing: URLError(.cancelled))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        lock.lock()
        if !messageQueue.isEmpty {
            let result = messageQueue.removeFirst()
            lock.unlock()
            switch result {
            case .success(let msg): return msg
            case .failure(let err): throw err
            }
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // Double-check: a message might have arrived between the unlock and here
            if !messageQueue.isEmpty {
                let result = messageQueue.removeFirst()
                lock.unlock()
                switch result {
                case .success(let msg): continuation.resume(returning: msg)
                case .failure(let err): continuation.resume(throwing: err)
                }
            } else {
                pendingContinuation = continuation
                lock.unlock()
            }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        sentMessages.append(message)
        lock.unlock()
        completionHandler(nil)
    }

    // MARK: - Test helpers

    /// Enqueue a message to be returned by the next `receive()` call.
    func enqueue(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        let cont = pendingContinuation
        if cont != nil { pendingContinuation = nil }
        if cont == nil {
            messageQueue.append(.success(message))
            lock.unlock()
        } else {
            lock.unlock()
            cont?.resume(returning: message)
        }
    }

    /// Enqueue an error to be thrown by the next `receive()` call.
    func enqueueError(_ error: Error) {
        lock.lock()
        let cont = pendingContinuation
        if cont != nil { pendingContinuation = nil }
        if cont == nil {
            messageQueue.append(.failure(error))
            lock.unlock()
        } else {
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    /// Return the last sent message as a decoded string, or nil.
    func lastSentString() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard case .string(let s) = sentMessages.last else { return nil }
        return s
    }
}
