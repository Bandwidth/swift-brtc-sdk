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

    /// Whether inbound calls should auto-accept (audio flows immediately) or be parked (awaiting explicit accept/decline).
    /// Defaults to `true` (auto-accept).
    public var autoAccept: Bool

    public init(
        websocketUrl: String? = nil,
        iceServers: [RTCIceServer]? = nil,
        iceTransportPolicy: RTCIceTransportPolicy? = nil,
        audioProcessing: AudioProcessingOptions = AudioProcessingOptions(),
        autoAccept: Bool = true
    ) {
        self.websocketUrl = websocketUrl
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.audioProcessing = audioProcessing
        self.autoAccept = autoAccept
    }
}
