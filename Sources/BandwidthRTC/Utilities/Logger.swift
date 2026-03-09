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
}

/// Simple logger for BRTC SDK.
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    var level: LogLevel = .warn

    private let osLog = os.Logger(subsystem: "com.bandwidth.rtc", category: "SDK")

    func debug(_ message: String) {
        guard level >= .debug else { return }
        osLog.debug("[BRTC] \(message, privacy: .public)")
    }

    func trace(_ message: String) {
        guard level >= .trace else { return }
        osLog.trace("[BRTC] \(message, privacy: .public)")
    }

    func info(_ message: String) {
        guard level >= .info else { return }
        osLog.info("[BRTC] \(message, privacy: .public)")
    }

    func warn(_ message: String) {
        guard level >= .warn else { return }
        osLog.warning("[BRTC] \(message, privacy: .public)")
    }

    func error(_ message: String) {
        guard level >= .error else { return }
        osLog.error("[BRTC] \(message, privacy: .public)")
    }
}
