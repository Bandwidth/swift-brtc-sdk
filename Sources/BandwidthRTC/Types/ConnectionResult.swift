import Foundation

/// Result of an outbound connection request.
public struct OutboundConnectionResult: Decodable, Sendable {
    public let accepted: Bool
}

/// Result of a hangup request.
public struct HangupResult: Decodable, Sendable {
    public let result: String?
}
