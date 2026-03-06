import Foundation

/// Metadata received when the BRTC platform is ready.
public struct ReadyMetadata: Decodable, Sendable {
    public let endpointId: String?
    public let deviceId: String?
    public let territory: String?
    public let region: String?

    // Accept any key structure from the server
    enum CodingKeys: String, CodingKey {
        case endpointId
        case deviceId
        case territory
        case region
        // Common alternate key names
        case endpoint_id
        case device_id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.endpointId = try container.decodeIfPresent(String.self, forKey: .endpointId)
            ?? container.decodeIfPresent(String.self, forKey: .endpoint_id)
        self.deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
            ?? container.decodeIfPresent(String.self, forKey: .device_id)
        self.territory = try container.decodeIfPresent(String.self, forKey: .territory)
        self.region = try container.decodeIfPresent(String.self, forKey: .region)
    }

    public init(endpointId: String? = nil, deviceId: String? = nil, territory: String? = nil, region: String? = nil) {
        self.endpointId = endpointId
        self.deviceId = deviceId
        self.territory = territory
        self.region = region
    }
}
