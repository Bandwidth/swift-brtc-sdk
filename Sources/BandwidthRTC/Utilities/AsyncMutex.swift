import Foundation

/// A FIFO mutex usable across `await` suspension points.
///
/// `NSLock` cannot be held across an `await` (a suspended task would block whichever thread
/// happens to resume it, not just its own), and an actor's own isolation can't be released
/// mid-method the way `unpublish` needs to (it must drop this lock while it polls for the
/// publish peer to reconnect - a wait that can take up to 10s - so a concurrent `publish()` or
/// gateway ICE-restart offer is not blocked for that long). This provides `lock()`/`unlock()` as
/// separate, ordinary calls so a caller can release the lock from the middle of an async
/// function instead of only at the end of a `withLock` block.
final class AsyncMutex: @unchecked Sendable {
    private let state = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until the lock is free, then takes it.
    func lock() async {
        let mustWait: Bool = {
            state.lock(); defer { state.unlock() }
            if isLocked {
                return true
            }
            isLocked = true
            return false
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            state.lock()
            waiters.append(continuation)
            state.unlock()
        }
    }

    /// Releases the lock, handing it directly to the next waiter (if any) rather than letting a
    /// new `lock()` call race it for the freed slot.
    func unlock() {
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

    /// Runs `body` while holding the lock, unlocking afterward even if `body` throws.
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}
