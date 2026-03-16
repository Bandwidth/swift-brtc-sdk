import Foundation

/// Protocol abstracting SignalingClient for testability.
protocol SignalingClientProtocol: AnyObject, Sendable {
    func connect(authParams: RtcAuthParams, options: RtcOptions?) async throws
    func disconnect() async
    func onEvent(_ method: String, handler: @escaping @Sendable (Data) -> Void) async
    func removeEventHandler(_ method: String) async
    func setMediaPreferences() async throws -> SetMediaPreferencesResult
    func offerSdp(sdpOffer: String, peerType: String) async throws -> OfferSdpResult
    func answerSdp(sdpAnswer: String, peerType: String) async throws
    func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult
    func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult
}

extension SignalingClient: SignalingClientProtocol {}
