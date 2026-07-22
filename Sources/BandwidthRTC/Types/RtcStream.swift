import Foundation
import WebRTC

/// Represents a published or subscribed media stream.
public struct RtcStream: Sendable {
    /// The underlying WebRTC media stream.
    public let mediaStream: RTCMediaStream

    /// The types of media in this stream.
    public let mediaTypes: [MediaType]

    /// Optional alias assigned during publishing.
    public let alias: String?

    /// The caller's identity for inbound calls (populated from trackMetadata).
    public let from: String?

    /// The caller's identity type (e.g., "phone") for inbound calls.
    public let fromType: String?

    /// Whether this inbound call was auto-accepted by the gateway (true) or is parked waiting for accept/decline.
    public let autoAccepted: Bool?

    /// Optional tags associated with the call.
    public let tags: String?

    public init(
        mediaStream: RTCMediaStream,
        mediaTypes: [MediaType],
        alias: String? = nil,
        from: String? = nil,
        fromType: String? = nil,
        autoAccepted: Bool? = nil,
        tags: String? = nil
    ) {
        self.mediaStream = mediaStream
        self.mediaTypes = mediaTypes
        self.alias = alias
        self.from = from
        self.fromType = fromType
        self.autoAccepted = autoAccepted
        self.tags = tags
    }

    /// The stream identifier.
    public var streamId: String {
        mediaStream.streamId
    }
}
