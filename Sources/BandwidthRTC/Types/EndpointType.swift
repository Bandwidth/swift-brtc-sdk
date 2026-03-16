import Foundation

/// The type of endpoint for outbound connections and hangups.
public enum EndpointType: String, Codable, Sendable {
    case endpoint = "ENDPOINT"
    case callId = "CALL_ID"
    case phoneNumber = "PHONE_NUMBER"
}
