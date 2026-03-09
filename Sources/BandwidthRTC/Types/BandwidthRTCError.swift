import Foundation

/// Errors that can occur during BRTC operations.
public enum BandwidthRTCError: Error, LocalizedError, Equatable {
    case invalidToken
    case connectionFailed(String)
    case signalingError(String)
    case webSocketDisconnected
    case sdpNegotiationFailed(String)
    case mediaAccessDenied
    case alreadyConnected
    case notConnected
    case publishFailed(String)
    case rpcError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Invalid or expired endpoint token"
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .signalingError(let detail):
            return "Signaling error: \(detail)"
        case .webSocketDisconnected:
            return "WebSocket disconnected unexpectedly"
        case .sdpNegotiationFailed(let detail):
            return "SDP negotiation failed: \(detail)"
        case .mediaAccessDenied:
            return "Camera or microphone access denied"
        case .alreadyConnected:
            return "Already connected to BRTC"
        case .notConnected:
            return "Not connected to BRTC"
        case .publishFailed(let detail):
            return "Publish failed: \(detail)"
        case .rpcError(let code, let message):
            return "RPC error (\(code)): \(message)"
        }
    }
}
