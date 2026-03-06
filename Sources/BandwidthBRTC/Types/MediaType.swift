import Foundation

/// Types of media that can be published or subscribed to.
public enum MediaType: String, Codable, Sendable {
    case audio = "AUDIO"
    case video = "VIDEO"
    case application = "APPLICATION"
}
