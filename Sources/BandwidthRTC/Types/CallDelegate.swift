import Foundation

/// Delegate protocol for receiving high-level call lifecycle events from the SDK.
///
/// When `callDelegate` is set on `BandwidthRTCClient`, the SDK automatically manages
/// CallKit integration and reports call state changes through this protocol.
///
/// The raw stream callbacks (`onStreamAvailable`, `onStreamUnavailable`, etc.) continue
/// to fire regardless of whether a delegate is set.
public protocol BandwidthRTCCallDelegate: AnyObject, Sendable {
    /// Called when the call state changes.
    @MainActor func bandwidthRTC(_ client: BandwidthRTCClient, callDidChangeState state: CallState, info: CallInfo)

    /// Called when an incoming call is detected.
    ///
    /// On a real device, CallKit's native incoming call UI is shown automatically before this fires.
    /// On the simulator, CallKit is not available so the app should show its own ringing UI.
    ///
    /// The app should eventually call `client.answerCall()` or `client.rejectCall()`.
    @MainActor func bandwidthRTC(_ client: BandwidthRTCClient, didReceiveIncomingCall info: CallInfo)

    /// Called when a call-related error occurs.
    @MainActor func bandwidthRTC(_ client: BandwidthRTCClient, callDidFailWithError error: Error, info: CallInfo?)
}

// Default implementations for optional methods.
public extension BandwidthRTCCallDelegate {
    func bandwidthRTC(_ client: BandwidthRTCClient, callDidFailWithError error: Error, info: CallInfo?) {}
}
