import Foundation
import os

/// Log level for the BRTC SDK.
public enum LogLevel: Int, Comparable, Sendable {
    case off = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4
    case trace = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Lowercase name, as reported to the gateway in diagnostics.
    var name: String {
        switch self {
        case .off: return "off"
        case .error: return "error"
        case .warn: return "warn"
        case .info: return "info"
        case .debug: return "debug"
        case .trace: return "trace"
        }
    }
}

/// Simple logger for BRTC SDK.
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    var level: LogLevel = .warn

    private let osLog = os.Logger(subsystem: "com.bandwidth.rtc", category: "SDK")

    private let observersLock = NSLock()
    private var observers: [UUID: @Sendable (LogLevel, String) -> Void] = [:]

    /// Registers a callback for every log call, whatever `level` is set to. Observers run
    /// synchronously on the logging thread and must not log themselves.
    func addObserver(_ observer: @escaping @Sendable (LogLevel, String) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        observersLock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    private func notifyObservers(_ level: LogLevel, _ message: String) {
        observersLock.lock()
        let current = Array(observers.values)
        observersLock.unlock()
        for observer in current {
            observer(level, message)
        }
    }

    func debug(_ message: String) {
        notifyObservers(.debug, message)
        guard level >= .debug else { return }
        osLog.debug("[BRTC] \(message, privacy: .public)")
    }

    func trace(_ message: String) {
        notifyObservers(.trace, message)
        guard level >= .trace else { return }
        osLog.trace("[BRTC] \(message, privacy: .public)")
    }

    func info(_ message: String) {
        notifyObservers(.info, message)
        guard level >= .info else { return }
        osLog.info("[BRTC] \(message, privacy: .public)")
    }

    func warn(_ message: String) {
        notifyObservers(.warn, message)
        guard level >= .warn else { return }
        osLog.warning("[BRTC] \(message, privacy: .public)")
    }

    func error(_ message: String) {
        notifyObservers(.error, message)
        guard level >= .error else { return }
        osLog.error("[BRTC] \(message, privacy: .public)")
    }
}
