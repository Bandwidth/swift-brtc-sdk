import Foundation

/// Metadata about a track from a remote call source, keyed by track ID.
public struct TrackMetadata: Codable, Sendable {
    public let from: String?
    public let fromType: String?
    public let autoAccepted: Bool?
    public let tags: String?

    public init(
        from: String? = nil,
        fromType: String? = nil,
        autoAccepted: Bool? = nil,
        tags: String? = nil
    ) {
        self.from = from
        self.fromType = fromType
        self.autoAccepted = autoAccepted
        self.tags = tags
    }
}
