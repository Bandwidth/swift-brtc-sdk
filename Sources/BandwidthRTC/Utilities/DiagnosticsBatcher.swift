import Foundation

/// Collects every SDK log call, at all levels and regardless of the configured log level, so the
/// signaling layer can ship them to the gateway as `deviceDiagnostics`. Thread safe.
final class DiagnosticsBatcher: @unchecked Sendable {
    /// Upper bound on buffered entries. Without it a long offline period, when nothing can be
    /// flushed, would grow memory without limit; the oldest entries are dropped first.
    static let defaultMaxEntries = 5000

    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [DiagnosticsLogEntry] = []
    /// Index of the oldest live entry. Advancing it drops the oldest in O(1); the dead prefix is
    /// compacted once it grows as large as the cap.
    private var head = 0
    private var observerId: UUID?

    init(maxEntries: Int = DiagnosticsBatcher.defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    deinit {
        if let observerId {
            Logger.shared.removeObserver(observerId)
        }
    }

    /// Starts capturing log calls. No-op when already capturing.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard observerId == nil else { return }
        observerId = Logger.shared.addObserver { [weak self] level, message in
            self?.record(level: level, message: message)
        }
    }

    /// Stops capturing. Entries already buffered stay until `drain()` or `discard()`.
    func stop() {
        lock.lock()
        let id = observerId
        observerId = nil
        lock.unlock()
        if let id {
            Logger.shared.removeObserver(id)
        }
    }

    /// Removes and returns every buffered entry, oldest first.
    func drain() -> [DiagnosticsLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let drained = Array(entries[head...])
        entries.removeAll()
        head = 0
        return drained
    }

    func discard() {
        _ = drain()
    }

    func record(level: LogLevel, message: String) {
        let entry = DiagnosticsLogEntry(
            level: level.name,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            message: [message]
        )
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count - head > maxEntries {
            head += 1
        }
        if head >= maxEntries {
            entries.removeFirst(head)
            head = 0
        }
    }
}
