import Foundation
@testable import BandwidthRTC

/// Mock SignalingClient for testing BandwidthRTC without real network connections.
/// Implemented as a class (not actor) so tests can configure it without `await`.
final class MockSignalingClient: @unchecked Sendable, SignalingClientProtocol {

    private let lock = NSLock()

    // MARK: - Configuration (set before calling connect)

    var shouldThrowOnConnect: Error? = nil
    var shouldThrowOnSetMediaPreferences: Error? = nil
    var shouldThrowOnOfferSdp: Error? = nil
    var shouldThrowOnAnswerSdp: Error? = nil
    var shouldThrowOnRequestOutbound: Error? = nil
    var shouldThrowOnHangup: Error? = nil

    var setMediaPreferencesResult = SetMediaPreferencesResult(
        endpointId: "mock-endpoint",
        deviceId: "mock-device",
        publishSdpOffer: nil,
        subscribeSdpOffer: nil
    )
    var offerSdpResult = OfferSdpResult(sdpAnswer: "mock-sdp-answer")
    var requestOutboundResult = OutboundConnectionResult(accepted: true)
    var hangupResult = HangupResult(result: "ok")

    // MARK: - Concurrency support

    /// Optional delay (in milliseconds) to simulate network latency on connect.
    var connectDelayMs: UInt64 = 0
    /// Optional delay (in milliseconds) to simulate network latency on offerSdp.
    var offerSdpDelayMs: UInt64 = 0
    /// Optional delay (in milliseconds) to simulate network latency on setMediaPreferences.
    var setMediaPreferencesDelayMs: UInt64 = 0

    // MARK: - Captured calls

    private(set) var connectCalledCount = 0
    private(set) var disconnectCalledCount = 0
    private(set) var answerSdpCalls: [(sdpAnswer: String, peerType: String)] = []
    private(set) var offerSdpCallCount = 0
    private(set) var registeredEvents: [String] = []
    private(set) var removedEvents: [String] = []
    private(set) var requestOutboundCalls: [(id: String, type: EndpointType)] = []
    private(set) var hangupCalls: [(endpoint: String, type: EndpointType)] = []

    // MARK: - Internal event handlers

    private var eventHandlers: [String: @Sendable (Data) -> Void] = [:]

    // MARK: - SignalingClientProtocol

    func connect(authParams: RtcAuthParams, options: RtcOptions?) async throws {
        lock.lock()
        connectCalledCount += 1
        let error = shouldThrowOnConnect
        let delay = connectDelayMs
        lock.unlock()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
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
        let delay = setMediaPreferencesDelayMs
        lock.unlock()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        if let error { throw error }
        return result
    }

    func offerSdp(sdpOffer: String, peerType: String) async throws -> OfferSdpResult {
        lock.lock()
        let error = shouldThrowOnOfferSdp
        let result = offerSdpResult
        let delay = offerSdpDelayMs
        offerSdpCallCount += 1
        lock.unlock()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        if let error { throw error }
        return result
    }

    func answerSdp(sdpAnswer: String, peerType: String) async throws {
        lock.lock()
        answerSdpCalls.append((sdpAnswer: sdpAnswer, peerType: peerType))
        let error = shouldThrowOnAnswerSdp
        lock.unlock()
        if let error { throw error }
    }

    func requestOutboundConnection(id: String, type: EndpointType) async throws -> OutboundConnectionResult {
        lock.lock()
        requestOutboundCalls.append((id: id, type: type))
        let result = requestOutboundResult
        let error = shouldThrowOnRequestOutbound
        lock.unlock()
        if let error { throw error }
        return result
    }

    func hangupConnection(endpoint: String, type: EndpointType) async throws -> HangupResult {
        lock.lock()
        hangupCalls.append((endpoint: endpoint, type: type))
        let result = hangupResult
        let error = shouldThrowOnHangup
        lock.unlock()
        if let error { throw error }
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

    /// Check if a specific event handler is registered.
    func hasEventHandler(for method: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventHandlers[method] != nil
    }
}
