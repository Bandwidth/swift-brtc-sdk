import Foundation

/// The terminal status of a `<Connect>` verb.
public enum ConnectStatus: String, Codable, Sendable {
    case initiated = "INITIATED"
    case completed = "COMPLETED"
    case timedOut = "TIMED_OUT"
    case denied = "DENIED"
    case canceled = "CANCELED"
    case failed = "FAILED"
}
