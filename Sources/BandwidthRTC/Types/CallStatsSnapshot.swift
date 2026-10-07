import Foundation

/// A snapshot of WebRTC call statistics at a point in time.
public struct CallStatsSnapshot: Sendable {
    // Inbound (subscribe PC)
    public var packetsReceived: Int = 0
    public var packetsLost: Int = 0
    public var bytesReceived: Int = 0
    public var jitter: Double = 0          // seconds
    public var audioLevel: Double = 0      // 0.0 to 1.0

    // Outbound (publish PC)
    public var packetsSent: Int = 0
    public var bytesSent: Int = 0

    // RTCP receiver report (remote-inbound-rtp on publish PC)
    public var remoteFractionLost: Double = 0 // 0.0 to 1.0
    public var remoteJitter: Double = 0       // seconds
    public var rtcpRoundTripTime: Double = 0  // seconds

    // Derived / extra
    public var roundTripTime: Double = 0   // seconds (from candidate-pair)
    public var codec: String = "unknown"   // e.g. "opus"
    public var inboundBitrate: Double = 0  // bits per second (calculated)
    public var outboundBitrate: Double = 0 // bits per second (calculated)
    public var timestamp: TimeInterval = 0

    public init() {}
}
