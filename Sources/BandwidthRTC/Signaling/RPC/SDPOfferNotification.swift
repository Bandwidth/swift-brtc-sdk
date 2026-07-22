import Foundation

/// Server-to-client notification containing a new SDP offer for subscribing.
struct SDPOfferNotification: Decodable {
    let endpointId: String?
    let peerType: String?
    let sdpOffer: String
    let sdpRevision: Int?
    let trackMetadata: [String: TrackMetadata]?
}
