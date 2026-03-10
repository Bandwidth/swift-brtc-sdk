import AVFoundation
import CallKit
import WebRTC

/// Internal CallKit manager that wraps CXProvider and CXCallController.
///
/// Handles the native iOS incoming/outgoing call UI, audio session coordination
/// with WebRTC, and communicates user actions back to the owning `BandwidthRTCClient`.
final class CallKitManager: NSObject, CXProviderDelegate, @unchecked Sendable {

    // MARK: - Callbacks (to BandwidthRTCClient)

    /// Called when the user taps Accept on the native call UI.
    var onUserAnswered: ((UUID) -> Void)?

    /// Called when the user taps Decline or End on the native call UI.
    var onUserEnded: ((UUID) -> Void)?

    // MARK: - State

    private(set) var activeCallUUID: UUID?

    // MARK: - CallKit

    private let provider: CXProvider
    private let callController = CXCallController()

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil) // nil = main queue
    }

    // MARK: - Incoming Call

    /// Show the native iOS incoming call screen.
    func reportIncomingCall(
        callerName: String,
        hasVideo: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        let uuid = UUID()
        activeCallUUID = uuid

        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true

        #if targetEnvironment(simulator)
        // CallKit does not work on the simulator. Skip the CXProvider call
        // and directly notify so the app can show its own ringing UI.
        Logger.shared.warn("CallKit not available on simulator — skipping CXProvider.reportNewIncomingCall")
        completion(nil)
        #else
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                self.activeCallUUID = nil
                Logger.shared.error("Failed to report incoming call: \(error)")
            }
            completion(error)
        }
        #endif
    }

    // MARK: - Outgoing Call

    /// Report that an outgoing call has started connecting.
    func reportOutgoingCallStarted(uuid: UUID) {
        activeCallUUID = uuid
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    /// Report that an outgoing call has connected.
    func reportOutgoingCallConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // MARK: - Call Ended

    /// Tell CallKit a call ended (e.g. remote hangup or local hangup).
    func reportCallEnded(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        activeCallUUID = nil
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        onUserAnswered?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        if uuid == activeCallUUID {
            onUserEnded?(uuid)
            activeCallUUID = nil
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Inform WebRTC that CallKit activated the audio session
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }

    // MARK: - Manual Audio Session (non-CallKit outbound calls)

    /// Configures and activates the audio session for outbound calls that don't
    /// go through CallKit. Must be called after the call is established.
    func activateAudioSessionForOutboundCall() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            RTCAudioSession.sharedInstance().audioSessionDidActivate(session)
        } catch {
            Logger.shared.error("Failed to activate audio session: \(error)")
        }
    }

    func deactivateAudioSessionForOutboundCall() {
        let session = AVAudioSession.sharedInstance()
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(session)
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.shared.error("Failed to deactivate audio session: \(error)")
        }
    }
}
