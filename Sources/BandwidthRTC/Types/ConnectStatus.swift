import Foundation

/// The terminal outcome of a `<Connect>` verb execution.
public enum ConnectStatus: String, Decodable, Sendable {
    case initiated = "INITIATED"
    case completed = "COMPLETED"
    case timedOut = "TIMED_OUT"
    case denied = "DENIED"
    case canceled = "CANCELED"
    case failed = "FAILED"
}
