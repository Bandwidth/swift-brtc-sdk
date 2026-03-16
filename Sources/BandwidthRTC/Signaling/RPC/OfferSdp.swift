import Foundation

struct OfferSdpParams: Codable {
    let sdpOffer: String
    let peerType: String
}

struct OfferSdpResult: Decodable {
    let sdpAnswer: String
}
