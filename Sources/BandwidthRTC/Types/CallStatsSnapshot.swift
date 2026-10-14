import Foundation

/// Audio RTP packet and byte counters read from one peer connection's own stats report.
public struct PeerCallStats: Sendable {
    public var packetsSent: Int = 0
    public var bytesSent: Int = 0
    public var packetsReceived: Int = 0
    public var bytesReceived: Int = 0

    public init() {}
}

/// A snapshot of WebRTC call statistics at a point in time.
///
/// A field that is not reported yet is 0, so 0 does not always mean a perfect value.
/// RTCP fields are 0 until the first receiver report arrives.
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
    public var roundTripTime: Double = 0   // seconds (from the selected candidate-pair)
    public var codec: String = "unknown"   // e.g. "opus"
    public var inboundBitrate: Double = 0  // bits per second (calculated)
    public var outboundBitrate: Double = 0 // bits per second (calculated)
    public var timestamp: TimeInterval = 0

    // Per-peer counters, so stats can be attributed to the peer connection they came from
    /// The peer connection that sends local media.
    public var publishPeer = PeerCallStats()
    /// The peer connection that receives remote media.
    public var subscribePeer = PeerCallStats()

    public init() {}
}
