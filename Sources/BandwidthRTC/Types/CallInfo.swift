import Foundation

/// Metadata about a call managed by the SDK's CallKit integration.
public struct CallInfo: Sendable {
    /// Unique identifier for this call (used internally by CallKit).
    public let callUUID: UUID

    /// Whether this call is inbound or outbound.
    public let direction: CallDirection

    /// The remote party identifier (phone number, endpoint ID, or display name).
    public let remoteParty: String?

    /// When the call was initiated.
    public let startTime: Date

    public init(callUUID: UUID = UUID(), direction: CallDirection, remoteParty: String? = nil, startTime: Date = Date()) {
        self.callUUID = callUUID
        self.direction = direction
        self.remoteParty = remoteParty
        self.startTime = startTime
    }

    /// Direction of a call.
    public enum CallDirection: String, Sendable {
        case inbound
        case outbound
    }
}
