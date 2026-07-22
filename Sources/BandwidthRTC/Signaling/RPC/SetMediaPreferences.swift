import Foundation

struct SetMediaPreferencesParams: Codable {
    let `protocol`: String
    let autoAccept: Bool

    init(autoAccept: Bool = true) {
        self.protocol = "WEBRTC"
        self.autoAccept = autoAccept
    }

    enum CodingKeys: String, CodingKey {
        case `protocol` = "protocol"
        case autoAccept = "autoAccept"
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
