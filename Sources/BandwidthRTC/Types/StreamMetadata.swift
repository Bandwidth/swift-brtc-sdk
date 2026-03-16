import Foundation

/// Metadata about a remote stream source, received from the server.
public struct StreamMetadata: Codable, Sendable {
    public let endpointId: String?
    public let alias: String?
    public let mediaTypes: [MediaType]?
}
