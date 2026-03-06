import Foundation
import WebRTC

/// Configuration options for the BRTC connection.
public struct RtcOptions: Sendable {
    /// Override the default WebSocket gateway URL.
    public var websocketUrl: String?

    /// Custom ICE servers (STUN/TURN).
    public var iceServers: [RTCIceServer]?

    /// ICE transport policy. Defaults to `.all`.
    public var iceTransportPolicy: RTCIceTransportPolicy?

    public init(
        websocketUrl: String? = nil,
        iceServers: [RTCIceServer]? = nil,
        iceTransportPolicy: RTCIceTransportPolicy? = nil
    ) {
        self.websocketUrl = websocketUrl
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
    }
}
