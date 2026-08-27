import Foundation

/// Fired once per DTMF tone queued for local playback on a published stream.
/// Reflects local injection into the outbound stream only — no delivery confirmation
/// from the remote party (RFC 4733 has no ack).
public struct DtmfSentEvent: Sendable {
    /// The DTMF tone that was queued, e.g. "1" or "#"
    public let tone: String
    /// Id of the published stream the tone was sent on
    public let streamId: String
}
