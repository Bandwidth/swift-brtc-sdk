import Foundation

/// A FIFO mutex whose critical section can span `await` suspension points.
///
/// Publish-side negotiation (create offer, send it to the gateway, apply the answer) suspends
/// between steps and must not interleave with another negotiation on the same peer connection.
/// `NSLock` cannot be held across an `await`, and an actor does not help because actors are
/// reentrant at every `await`.
final class AsyncMutex: @unchecked Sendable {
    private let state = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` while holding the lock, unlocking afterward even if `body` throws.
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }

    /// Suspends until the lock is free, then takes it.
    private func lock() async {
        // Check and enqueue under one critical section so an unlock() cannot slip in between
        // and leave this waiter parked forever.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.lock()
            if isLocked {
                waiters.append(continuation)
                state.unlock()
            } else {
                isLocked = true
                state.unlock()
                continuation.resume()
            }
        }
    }

    /// Releases the lock, handing it directly to the next waiter (if any) rather than letting a
    /// new `lock()` call race it for the freed slot.
    private func unlock() {
        state.lock()
        if waiters.isEmpty {
            isLocked = false
            state.unlock()
        } else {
            let next = waiters.removeFirst()
            state.unlock()
            next.resume()
        }
    }
}
