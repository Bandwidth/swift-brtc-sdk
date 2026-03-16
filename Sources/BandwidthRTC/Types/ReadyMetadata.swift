import Foundation

/// Metadata received when the BRTC platform is ready.
public struct ReadyMetadata: Decodable, Sendable {
    public let endpointId: String?
    public let deviceId: String?
    public let territory: String?
    public let region: String?

    public init(endpointId: String? = nil, deviceId: String? = nil, territory: String? = nil, region: String? = nil) {
        self.endpointId = endpointId
        self.deviceId = deviceId
        self.territory = territory
        self.region = region
    }
}
