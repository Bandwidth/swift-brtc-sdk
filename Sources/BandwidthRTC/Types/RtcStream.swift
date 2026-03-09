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

    public init(mediaStream: RTCMediaStream, mediaTypes: [MediaType], alias: String? = nil) {
        self.mediaStream = mediaStream
        self.mediaTypes = mediaTypes
        self.alias = alias
    }

    /// The stream identifier.
    public var streamId: String {
        mediaStream.streamId
    }
}
