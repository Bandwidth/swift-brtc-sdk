import Foundation

/// One captured SDK log call, in the shape the gateway's `deviceDiagnostics` notification expects.
struct DiagnosticsLogEntry: Codable, Equatable, Sendable {
    let level: String
    /// Epoch milliseconds.
    let timestamp: Int64
    let message: [String]
}

struct DeviceDiagnosticsParams: Codable {
    let logs: [DiagnosticsLogEntry]
}
