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

    /// Audio processing and format options. Defaults to SDK defaults (48 kHz, mono, voiceChat mode).
    public var audioProcessing: AudioProcessingOptions

    public init(
        websocketUrl: String? = nil,
        iceServers: [RTCIceServer]? = nil,
        iceTransportPolicy: RTCIceTransportPolicy? = nil,
        audioProcessing: AudioProcessingOptions = AudioProcessingOptions()
    ) {
        self.websocketUrl = websocketUrl
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.audioProcessing = audioProcessing
    }
}
