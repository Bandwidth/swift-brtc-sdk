import Foundation
import WebRTC
@testable import BandwidthRTC

/// Mock MixingAudioDevice for testing without requiring actual audio I/O.
final class MockMixingAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {

    // MARK: - Audio level callbacks

    var onLocalAudioLevel: (([Float32]) -> Void)?
    var onRemoteAudioLevel: (([Float32]) -> Void)?

    // MARK: - State tracking

    private(set) var recordingEnabled: Bool = false
    private(set) var playoutEnabled: Bool = false

    // MARK: - RTCAudioDevice Properties

    var deviceInputSampleRate: Double {
        return 48000.0
    }

    var inputIOBufferDuration: TimeInterval {
        return 0.01  // 10ms
    }

    var inputNumberOfChannels: Int {
        return 1
    }

    var inputLatency: TimeInterval {
        return 0.0
    }

    var deviceOutputSampleRate: Double {
        return 48000.0
    }

    var outputIOBufferDuration: TimeInterval {
        return 0.01  // 10ms
    }

    var outputNumberOfChannels: Int {
        return 1
    }

    var outputLatency: TimeInterval {
        return 0.0
    }

    private var _isInitialized: Bool = false
    var isInitialized: Bool {
        return _isInitialized
    }

    var isPlayoutInitialized: Bool {
        return playoutEnabled
    }

    var isPlaying: Bool {
        return playoutEnabled
    }

    var isRecordingInitialized: Bool {
        return recordingEnabled
    }

    var isRecording: Bool {
        return recordingEnabled
    }

    // MARK: - RTCAudioDevice Methods

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        _isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _isInitialized = false
        recordingEnabled = false
        playoutEnabled = false
        return true
    }

    func initializePlayout() -> Bool {
        playoutEnabled = true
        return true
    }

    func initializeRecording() -> Bool {
        recordingEnabled = true
        return true
    }

    // MARK: - Legacy compatibility methods (for backward compatibility)

    func audioDeviceModule() -> Any? {
        return self
    }

    func setDelegate(_ delegate: RTCAudioDeviceDelegate) {
        // Mock: no-op
    }

    func initRecording() -> Bool {
        return initializeRecording()
    }

    func initPlayout() -> Bool {
        return initializePlayout()
    }

    func startRecording() -> Bool {
        return recordingEnabled
    }

    func startPlayout() -> Bool {
        return playoutEnabled
    }

    func stopRecording() -> Bool {
        recordingEnabled = false
        return true
    }

    func stopPlayout() -> Bool {
        playoutEnabled = false
        return true
    }

    func terminateAudioDevice() {
        _ = terminateDevice()
    }

    // MARK: - Other required RTCAudioDevice methods (stubs)

    func playoutSampleRate() -> UInt32 {
        return 48000
    }

    func recordingSampleRate() -> UInt32 {
        return 48000
    }

    func recordingChannels() -> UInt32 {
        return 1
    }

    func playoutChannels() -> UInt32 {
        return 1
    }

    func recordingBufferSize() -> UInt32 {
        return 480  // 10ms at 48kHz
    }

    func playoutBufferSize() -> UInt32 {
        return 480  // 10ms at 48kHz
    }

    // MARK: - File audio simulation

    func loadFile(url: URL) throws {
        // Mock: no-op
    }

    func startFilePlayback() {
        isPlayingFile = true
    }

    func stopFilePlayback() {
        isPlayingFile = false
    }
}
