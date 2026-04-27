import Foundation

/// Metadata received when the BRTC platform is ready.
public struct ReadyMetadata: Decodable, Sendable {
    public let endpointId: String?
    public let deviceId: String?
    public let territory: String?
    public let region: String?
    public let connectStatus: ConnectStatus?
    public let accountId: String?
    public let sessionId: String?
    public let from: String?
    public let fromType: String?
    public let fromTags: String?
    public let to: String?
    public let toType: String?
    public let toTags: String?

    public init(
        endpointId: String? = nil,
        deviceId: String? = nil,
        territory: String? = nil,
        region: String? = nil,
        connectStatus: ConnectStatus? = nil,
        accountId: String? = nil,
        sessionId: String? = nil,
        from: String? = nil,
        fromType: String? = nil,
        fromTags: String? = nil,
        to: String? = nil,
        toType: String? = nil,
        toTags: String? = nil
    ) {
        self.endpointId = endpointId
        self.deviceId = deviceId
        self.territory = territory
        self.region = region
        self.connectStatus = connectStatus
        self.accountId = accountId
        self.sessionId = sessionId
        self.from = from
        self.fromType = fromType
        self.fromTags = fromTags
        self.to = to
        self.toType = toType
        self.toTags = toTags
    }
}
