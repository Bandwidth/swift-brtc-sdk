import Foundation

struct HangupConnectionParams: Codable {
    let endpoint: String
    let type: EndpointType
}
