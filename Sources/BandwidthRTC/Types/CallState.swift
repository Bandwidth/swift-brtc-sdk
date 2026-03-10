import Foundation

/// The state of a call managed by the SDK's CallKit integration.
public enum CallState: String, Sendable {
    /// No active call.
    case idle
    /// Incoming call reported to CallKit, awaiting user action.
    case ringing
    /// User answered; media being established.
    case connecting
    /// Audio flowing, call is active.
    case active
    /// Call has ended (local or remote hangup).
    case ended
}
