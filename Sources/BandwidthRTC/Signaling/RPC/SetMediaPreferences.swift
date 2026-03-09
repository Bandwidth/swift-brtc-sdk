import Foundation

struct SetMediaPreferencesParams: Codable {
    let `protocol`: String

    init() {
        self.protocol = "WEBRTC"
    }

    enum CodingKeys: String, CodingKey {
        case `protocol` = "protocol"
    }
}

struct SdpOffer: Decodable {
    let peerType: String?
    let sdpOffer: String
}

struct SetMediaPreferencesResult: Decodable {
    let endpointId: String?
    let deviceId: String?
    let publishSdpOffer: SdpOffer?
    let subscribeSdpOffer: SdpOffer?
}
