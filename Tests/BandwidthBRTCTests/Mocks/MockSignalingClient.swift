import Foundation
@testable import BandwidthBRTC

/// Mock SignalingClient for testing BandwidthRTC without real network connections.
/// Implemented as a class (not actor) so tests can configure it without `await`.
final class MockSignalingClient: @unchecked Sendable, SignalingClientProtocol {

    private let lock = NSLock()

    // MARK: - Configuration (set before calling connect)

    var shouldThrowOnConnect: Error? = nil
    var shouldThrowOnSetMediaPreferences: Error? = nil
    var shouldThrowOnOfferSdp: Error? = nil

    var setMediaPreferencesResult = SetMediaPreferencesResult(
        endpointId: "mock-endpoint",
        deviceId: "mock-device",
        publishSdpOffer: nil,
        subscribeSdpOffer: nil
    )
    var offerSdpResult = OfferSdpResult(sdpAnswer: "mock-sdp-answer")
    var requestOutboundResult = OutboundConnectionResult(accepted: true)
    var hangupResult = HangupResult(result: "ok")

    // MARK: - Captured calls

    private(set) var connectCalledCount = 0
    private(set) var disconnectCalledCount = 0
    private(set) var answerSdpCalls: [(sdpAnswer: String, peerType: String)] = []
    private(set) var registeredEvents: [String] = []
    private(set) var removedEvents: [String] = []

    // MARK: - Internal event handlers

    private var eventHandlers: [String: @Sendable (Data) -> Void] = [:]

    // MARK: - SignalingClientProtocol

    func connect(authParams: RtcAuthParams, options: RtcOptions?) async throws {
        lock.lock()
        connectCalledCount += 1
        let error = shouldThrowOnConnect
        lock.unlock()
        if let error { throw error }
    }

    func disconnect() async {
        lock.lock()
        disconnectCalledCount += 1
        lock.unlock()
    }

    func onEvent(_ method: String, handler: @escaping @Sendable (Data) -> Void) async {
        lock.lock()
        registeredEvents.append(method)
        eventHandlers[method] = handler
        lock.unlock()
    }

    func removeEventHandler(_ method: String) async {
        lock.lock()
        removedEvents.append(method)
        eventHandlers.removeValue(forKey: method)
        lock.unlock()
    }

    func setMediaPreferences() async throws -> SetMediaPreferencesResult {
        lock.lock()
        let error = shouldThrowOnSetMediaPreferences
        let result = setMediaPreferencesResult
        lock.unlock()
        if let error { throw error }
        return result
    }

    func offerSdp(sdpOffer: String, peerType: String) async throws -> OfferSdpResult {
        lock.lock()
        let error = shouldThrowOnOfferSdp
        let result = offerSdpResult
        lock.unlock()
        if let error { throw error }
        return result
    }

    func answerSdp(sdpAnswer: String, peerType: String) async throws {
        lock.lock()
        answerSdpCalls.append((sdpAnswer: sdpAnswer, peerType: peerType))
        lock.unlock()
    }

    func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult {
        lock.lock()
        let result = requestOutboundResult
        lock.unlock()
        return result
    }

    func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult {
        lock.lock()
        let result = hangupResult
        lock.unlock()
        return result
    }

    // MARK: - Test helpers

    /// Simulate the server delivering an event notification.
    func triggerEvent(_ method: String, data: Data = Data()) {
        lock.lock()
        let handler = eventHandlers[method]
        lock.unlock()
        handler?(data)
    }
}
