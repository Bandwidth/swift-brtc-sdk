import Foundation

/// Authentication parameters for connecting to BRTC.
public struct RtcAuthParams: Sendable {
    /// JWT endpoint token obtained from the Bandwidth Endpoints API.
    public let endpointToken: String

    public init(endpointToken: String) {
        self.endpointToken = endpointToken
    }
}
