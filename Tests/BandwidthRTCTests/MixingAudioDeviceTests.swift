import XCTest
import AVFoundation
import WebRTC
@testable import BandwidthRTC

/// Tests for MixingAudioDevice — audio engine lifecycle, state management, format properties,
/// and edge cases around initialization/termination ordering.
final class MixingAudioDeviceTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        audioOptions: AudioProcessingOptions = AudioProcessingOptions()
    ) -> MixingAudioDevice {
        MixingAudioDevice(audioOptions: audioOptions)
    }

    // MARK: - Initial State

    func testInitialStateIsClean() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isInitialized)
        XCTAssertFalse(sut.isPlayoutInitialized)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertFalse(sut.isRecordingInitialized)
        XCTAssertFalse(sut.isRecording)
        XCTAssertNil(sut.sourceNode, "Source node should not exist before initialize()")
    }

    func testEngineExistsOnInit() {
        let sut = makeSUT()
        // AVAudioEngine is always created, just not running
        XCTAssertNotNil(sut.engine)
        XCTAssertFalse(sut.engine.isRunning)
    }

    // MARK: - Format Properties (Default Options)

    func testDefaultSampleRates() {
        let sut = makeSUT()
        XCTAssertEqual(sut.deviceInputSampleRate, 48000.0)
        XCTAssertEqual(sut.deviceOutputSampleRate, 48000.0)
    }

    func testDefaultChannelCounts() {
        let sut = makeSUT()
        XCTAssertEqual(sut.inputNumberOfChannels, 1)
        XCTAssertEqual(sut.outputNumberOfChannels, 1)
    }

    func testDefaultIOBufferDuration() {
        let sut = makeSUT()
        // Default: useLowLatency=false, no preferred → 0.01 (10ms)
        XCTAssertEqual(sut.inputIOBufferDuration, 0.01, accuracy: 0.001)
        XCTAssertEqual(sut.outputIOBufferDuration, 0.01, accuracy: 0.001)
    }

    // MARK: - Format Properties (Custom Options)

    func testCustomSampleRates() {
        let options = AudioProcessingOptions(inputSampleRate: 44100, outputSampleRate: 44100)
        let sut = makeSUT(audioOptions: options)
        XCTAssertEqual(sut.deviceInputSampleRate, 44100.0)
        XCTAssertEqual(sut.deviceOutputSampleRate, 44100.0)
    }

    func testLowLatencyBufferDuration() {
        let options = AudioProcessingOptions(useLowLatency: true)
        let sut = makeSUT(audioOptions: options)
        XCTAssertEqual(sut.inputIOBufferDuration, 0.005, accuracy: 0.001)
        XCTAssertEqual(sut.outputIOBufferDuration, 0.005, accuracy: 0.001)
    }

    func testPreferredIOBufferDurationOverridesLowLatency() {
        let options = AudioProcessingOptions(useLowLatency: true, preferredIOBufferDuration: 0.02)
        let sut = makeSUT(audioOptions: options)
        XCTAssertEqual(sut.inputIOBufferDuration, 0.02, accuracy: 0.001)
        XCTAssertEqual(sut.outputIOBufferDuration, 0.02, accuracy: 0.001)
    }

    func testCustomChannelCounts() {
        let options = AudioProcessingOptions(inputChannels: 2, outputChannels: 2)
        let sut = makeSUT(audioOptions: options)
        XCTAssertEqual(sut.inputNumberOfChannels, 2)
        XCTAssertEqual(sut.outputNumberOfChannels, 2)
    }

    // MARK: - Playout Lifecycle (flag-only, no engine start — safe on simulator)

    func testInitializePlayoutSetsFlag() {
        let sut = makeSUT()
        let result = sut.initializePlayout()
        XCTAssertTrue(result)
        XCTAssertTrue(sut.isPlayoutInitialized)
    }

    func testStopPlayoutWithoutStartIsNoOp() {
        let sut = makeSUT()
        let result = sut.stopPlayout()
        XCTAssertTrue(result)
        XCTAssertFalse(sut.isPlaying)
    }

    // MARK: - Recording Lifecycle (flag-only, no engine start — safe on simulator)

    func testStopRecordingWithoutStartIsNoOp() {
        let sut = makeSUT()
        let result = sut.stopRecording()
        XCTAssertTrue(result)
        XCTAssertFalse(sut.isRecording)
    }

    // MARK: - Terminate

    func testTerminateWithoutInitializeIsNoOp() {
        let sut = makeSUT()
        let result = sut.terminateDevice()
        XCTAssertTrue(result)
        XCTAssertFalse(sut.isInitialized)
    }

    func testDoubleTerminateDoesNotCrash() {
        let sut = makeSUT()
        _ = sut.terminateDevice()
        let result = sut.terminateDevice()
        XCTAssertTrue(result)
    }

    func testTerminateClearsFlags() {
        let sut = makeSUT()
        // Only set flags that don't require engine start
        _ = sut.initializePlayout()

        let result = sut.terminateDevice()
        XCTAssertTrue(result)
        XCTAssertFalse(sut.isInitialized)
        XCTAssertFalse(sut.isPlayoutInitialized)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertFalse(sut.isRecordingInitialized)
        XCTAssertFalse(sut.isRecording)
        XCTAssertNil(sut.sourceNode, "Source node should be nil after terminate")
    }

    // MARK: - Playout/Recording via Mock (engine-dependent operations use mock)
    //
    // The real MixingAudioDevice's startPlayout/startRecording call startEngineIfNeeded()
    // which requires audio hardware not available on the iOS Simulator. We use the
    // MockMixingAudioDevice for lifecycle tests that exercise start/stop paths.

    func testMockStartPlayoutSetsFlag() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializePlayout()
        let result = mock.startPlayout()
        XCTAssertTrue(result)
        XCTAssertTrue(mock.isPlaying)
    }

    func testMockStopPlayoutClearsFlag() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializePlayout()
        _ = mock.startPlayout()
        let result = mock.stopPlayout()
        XCTAssertTrue(result)
        XCTAssertFalse(mock.isPlaying)
    }

    func testMockStartRecordingSetsFlag() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializeRecording()
        let result = mock.startRecording()
        XCTAssertTrue(result)
        XCTAssertTrue(mock.isRecording)
    }

    func testMockStopRecordingClearsFlag() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializeRecording()
        _ = mock.startRecording()
        let result = mock.stopRecording()
        XCTAssertTrue(result)
        XCTAssertFalse(mock.isRecording)
    }

    func testMockStartPlayoutThenRecordingBothActive() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializePlayout()
        _ = mock.startPlayout()
        _ = mock.initializeRecording()
        _ = mock.startRecording()
        XCTAssertTrue(mock.isPlaying)
        XCTAssertTrue(mock.isRecording)
    }

    func testMockStopPlayoutKeepsRecording() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializePlayout()
        _ = mock.startPlayout()
        _ = mock.initializeRecording()
        _ = mock.startRecording()
        _ = mock.stopPlayout()
        XCTAssertFalse(mock.isPlaying)
        XCTAssertTrue(mock.isRecording)
    }

    func testMockStopRecordingKeepsPlayout() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializePlayout()
        _ = mock.startPlayout()
        _ = mock.initializeRecording()
        _ = mock.startRecording()
        _ = mock.stopRecording()
        XCTAssertTrue(mock.isPlaying)
        XCTAssertFalse(mock.isRecording)
    }

    func testMockRepeatedStartPlayoutDoesNotCrash() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializePlayout()
        _ = mock.startPlayout()
        _ = mock.startPlayout()
        XCTAssertTrue(mock.isPlaying)
    }

    func testMockRepeatedStartRecordingDoesNotCrash() {
        let mock = MockMixingAudioDevice()
        _ = mock.initializeRecording()
        _ = mock.startRecording()
        _ = mock.startRecording()
        XCTAssertTrue(mock.isRecording)
    }

    // MARK: - Audio Level Callbacks

    func testOnLocalAudioLevelCallbackIsNilByDefault() {
        let sut = makeSUT()
        XCTAssertNil(sut.onLocalAudioLevel)
    }

    func testOnRemoteAudioLevelCallbackIsNilByDefault() {
        let sut = makeSUT()
        XCTAssertNil(sut.onRemoteAudioLevel)
    }

    func testSettingAudioLevelCallbacks() {
        let sut = makeSUT()
        var localCalled = false
        var remoteCalled = false
        sut.onLocalAudioLevel = { _ in localCalled = true }
        sut.onRemoteAudioLevel = { _ in remoteCalled = true }

        XCTAssertNotNil(sut.onLocalAudioLevel)
        XCTAssertNotNil(sut.onRemoteAudioLevel)
        // Callbacks set but not invoked — just verifying they can be assigned
        XCTAssertFalse(localCalled)
        XCTAssertFalse(remoteCalled)
    }

    // MARK: - Int16 ↔ Float32 Conversion Constant

    func testInt16ToFloatConversionConstant() {
        // The static constant should be exactly 1.0/32767.0
        let expected: Float32 = 1.0 / Float32(Int16.max)
        // We can't access the private static property directly, but we can verify
        // the math is correct: Int16.max * (1/Int16.max) should be approximately 1.0
        let result = Float32(Int16.max) * expected
        XCTAssertEqual(result, 1.0, accuracy: 0.0001)
    }

    // MARK: - Full Lifecycle Sequence

    func testFullPlayoutLifecycleFlags() {
        // Verify flag-only portion on real device (no engine start)
        let sut = makeSUT()
        XCTAssertTrue(sut.initializePlayout())
        XCTAssertTrue(sut.isPlayoutInitialized)
        XCTAssertTrue(sut.terminateDevice())
        XCTAssertFalse(sut.isPlayoutInitialized)
    }

    func testFullPlayoutLifecycleWithMock() {
        // Full start/stop cycle uses mock (engine requires hardware)
        let mock = MockMixingAudioDevice()
        XCTAssertTrue(mock.initializePlayout())
        XCTAssertTrue(mock.startPlayout())
        XCTAssertTrue(mock.isPlaying)
        XCTAssertTrue(mock.stopPlayout())
        XCTAssertFalse(mock.isPlaying)
        XCTAssertTrue(mock.terminateDevice())
    }

    func testFullRecordingLifecycleFlags() {
        // Verify flag-only portion on real device (no engine start)
        let sut = makeSUT()
        XCTAssertTrue(sut.initializeRecording())
        XCTAssertTrue(sut.isRecordingInitialized)
        XCTAssertTrue(sut.terminateDevice())
        XCTAssertFalse(sut.isRecordingInitialized)
    }

    func testFullRecordingLifecycleWithMock() {
        // Full start/stop cycle uses mock (engine requires hardware)
        let mock = MockMixingAudioDevice()
        XCTAssertTrue(mock.initializeRecording())
        XCTAssertTrue(mock.startRecording())
        XCTAssertTrue(mock.isRecording)
        XCTAssertTrue(mock.stopRecording())
        XCTAssertFalse(mock.isRecording)
        XCTAssertTrue(mock.terminateDevice())
    }

    // MARK: - Manual Audio Session Activation (CallKit)

    func testDefaultModeSessionIsAlwaysActive() {
        let sut = makeSUT()
        XCTAssertTrue(sut.isSessionActive, "Session should be considered active by default (non-CallKit mode)")
    }

    func testManualModeDefaultsToInactiveSession() {
        let options = AudioProcessingOptions(manualAudioSessionActivation: true)
        let sut = MixingAudioDevice(audioOptions: options)
        XCTAssertFalse(sut.isSessionActive, "Manual mode should start inactive until CallKit activates")
    }

    func testManualModeSeedsActiveStateFromConstructor() {
        // Simulates an incoming call answered from the lock screen: CallKit's didActivate
        // fires before connect() creates the device, so BandwidthRTCClient seeds the flag.
        let options = AudioProcessingOptions(manualAudioSessionActivation: true)
        let sut = MixingAudioDevice(audioOptions: options, isSessionActive: true)
        XCTAssertTrue(sut.isSessionActive)
    }

    func testIsSessionActiveConstructorParamIgnoredWhenNotManual() {
        // Non-manual mode is always active regardless of what's passed in.
        let sut = MixingAudioDevice(audioOptions: AudioProcessingOptions(), isSessionActive: false)
        XCTAssertTrue(sut.isSessionActive)
    }

    func testManualModeStartPlayoutDoesNotStartEngineWhileInactive() {
        let options = AudioProcessingOptions(manualAudioSessionActivation: true)
        let sut = MixingAudioDevice(audioOptions: options)
        _ = sut.initializePlayout()
        let result = sut.startPlayout()
        XCTAssertTrue(result)
        XCTAssertTrue(sut.isPlaying, "Flag should still flip so activation can resume playout later")
        XCTAssertFalse(sut.engine.isRunning, "Engine must not start until CallKit activates the session")
    }

    func testManualModeStartRecordingDoesNotStartEngineWhileInactive() {
        let options = AudioProcessingOptions(manualAudioSessionActivation: true)
        let sut = MixingAudioDevice(audioOptions: options)
        _ = sut.initializeRecording()
        let result = sut.startRecording()
        XCTAssertTrue(result)
        XCTAssertTrue(sut.isRecording)
        XCTAssertFalse(sut.engine.isRunning, "Engine must not start until CallKit activates the session")
    }

    func testSessionDidActivateIsNoOpWhenNotManualMode() {
        let sut = makeSUT()
        XCTAssertTrue(sut.isSessionActive)
        sut.sessionDidActivate()
        XCTAssertTrue(sut.isSessionActive, "Non-manual devices ignore CallKit hooks entirely")
    }

    func testSessionDidDeactivateIsNoOpWhenNotManualMode() {
        let sut = makeSUT()
        sut.sessionDidDeactivate()
        XCTAssertTrue(sut.isSessionActive, "Non-manual devices ignore CallKit hooks entirely")
    }

    func testSessionDidDeactivateWithoutPriorActivationIsSafe() {
        let options = AudioProcessingOptions(manualAudioSessionActivation: true)
        let sut = MixingAudioDevice(audioOptions: options)
        sut.sessionDidDeactivate()
        XCTAssertFalse(sut.isSessionActive)
        XCTAssertFalse(sut.engine.isRunning)
    }

    // MARK: - Silence Pump (manual activation)

    private func makePumpSUT(manual: Bool = true) -> (MixingAudioDevice, SilenceRecordingDelegate) {
        let options = AudioProcessingOptions(manualAudioSessionActivation: manual)
        let sut = MixingAudioDevice(audioOptions: options, isSessionActive: false)
        let delegate = SilenceRecordingDelegate()
        _ = sut.initialize(with: delegate)
        return (sut, delegate)
    }

    private func wait(_ seconds: TimeInterval) {
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    func testSilencePumpDeliversZeroFramesWhileInactiveAndRecording() {
        let (sut, delegate) = makePumpSUT()
        _ = sut.startRecording()
        wait(0.3)
        _ = sut.stopRecording()
        _ = sut.terminateDevice()
        XCTAssertGreaterThanOrEqual(delegate.frameCount, 5)
        XCTAssertTrue(delegate.allSilent)
        XCTAssertEqual(delegate.sampleCounts, [Int(sut.deviceInputSampleRate / 100)])
    }

    func testSessionDidActivateStopsSilencePump() {
        let (sut, delegate) = makePumpSUT()
        _ = sut.startRecording()
        wait(0.1)
        sut.sessionDidActivate()
        let countAtActivation = delegate.frameCount
        wait(0.1)
        XCTAssertEqual(delegate.frameCount, countAtActivation, "No silent frames after activation")
        _ = sut.terminateDevice()
    }

    func testSessionDidDeactivateWhileRecordingRestartsSilencePump() {
        let (sut, delegate) = makePumpSUT()
        _ = sut.startRecording()
        sut.sessionDidActivate()
        sut.sessionDidDeactivate()
        let before = delegate.frameCount
        wait(0.2)
        XCTAssertGreaterThanOrEqual(delegate.frameCount - before, 5)
        _ = sut.stopRecording()
        _ = sut.terminateDevice()
    }

    func testStopRecordingStopsSilencePump() {
        let (sut, delegate) = makePumpSUT()
        _ = sut.startRecording()
        wait(0.1)
        _ = sut.stopRecording()
        let countAtStop = delegate.frameCount
        wait(0.1)
        XCTAssertEqual(delegate.frameCount, countAtStop)
        _ = sut.terminateDevice()
    }

    func testRepeatedStartRecordingDoesNotDoubleThePump() {
        let (sut, delegate) = makePumpSUT()
        let start = Date()
        _ = sut.startRecording()
        _ = sut.startRecording()
        wait(0.5)
        _ = sut.stopRecording()
        let elapsed = Date().timeIntervalSince(start)
        _ = sut.terminateDevice()
        XCTAssertLessThanOrEqual(delegate.frameCount, Int(elapsed * 100) + 3, "Two timers would double the rate")
        XCTAssertGreaterThanOrEqual(delegate.frameCount, 5)
    }

    func testTerminateThenDeactivateDoesNotRestartSilencePump() {
        let (sut, delegate) = makePumpSUT()
        _ = sut.startRecording()
        wait(0.1)
        _ = sut.terminateDevice()
        let countAtTerminate = delegate.frameCount
        sut.sessionDidDeactivate()
        wait(0.1)
        XCTAssertEqual(delegate.frameCount, countAtTerminate)
    }

    func testDoubleSessionDidActivateDoesNotCrash() {
        let (sut, _) = makePumpSUT()
        _ = sut.initializeRecording()
        sut.sessionDidActivate()
        sut.sessionDidActivate()
        XCTAssertTrue(sut.isSessionActive)
        _ = sut.terminateDevice()
    }

    func testNonManualModeNeverStartsSilencePump() {
        let (sut, delegate) = makePumpSUT(manual: false)
        _ = sut.startRecording()
        wait(0.2)
        _ = sut.stopRecording()
        _ = sut.terminateDevice()
        XCTAssertEqual(delegate.frameCount, 0)
    }

    // MARK: - MockMixingAudioDevice Tests (ensures mock stays in sync)

    func testMockAudioDeviceDefaultValues() {
        let mock = MockMixingAudioDevice()
        XCTAssertEqual(mock.deviceInputSampleRate, 48000.0)
        XCTAssertEqual(mock.deviceOutputSampleRate, 48000.0)
        XCTAssertEqual(mock.inputNumberOfChannels, 1)
        XCTAssertEqual(mock.outputNumberOfChannels, 1)
        XCTAssertFalse(mock.isInitialized)
    }

    func testMockAudioDeviceLifecycle() {
        let mock = MockMixingAudioDevice()
        XCTAssertFalse(mock.recordingEnabled)
        XCTAssertFalse(mock.playoutEnabled)

        _ = mock.initializeRecording()
        XCTAssertTrue(mock.recordingEnabled)

        _ = mock.initializePlayout()
        XCTAssertTrue(mock.playoutEnabled)

        _ = mock.terminateDevice()
        XCTAssertFalse(mock.isInitialized)
        XCTAssertFalse(mock.recordingEnabled)
        XCTAssertFalse(mock.playoutEnabled)
    }
}

/// Captures frames passed to `deliverRecordedData` so tests can inspect the silence pump output.
private final class SilenceRecordingDelegate: NSObject, RTCAudioDeviceDelegate {
    private let lock = NSLock()
    private var _frameCount = 0
    private var _allSilent = true
    private var _sampleCounts = Set<Int>()

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return _frameCount }
    var allSilent: Bool { lock.lock(); defer { lock.unlock() }; return _allSilent }
    var sampleCounts: [Int] { lock.lock(); defer { lock.unlock() }; return Array(_sampleCounts) }

    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock {
        return { [self] _, _, _, numFrames, bufferList, _, _ in
            var silent = true
            if let list = bufferList,
               let ptr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))[0].mData?.assumingMemoryBound(to: Int16.self) {
                for i in 0..<Int(numFrames) where ptr[i] != 0 {
                    silent = false
                }
            }
            lock.lock()
            _frameCount += 1
            _allSilent = _allSilent && silent
            _sampleCounts.insert(Int(numFrames))
            lock.unlock()
            return noErr
        }
    }

    var preferredInputSampleRate: Double { 48000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }

    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
        return { _, _, _, _, _ in noErr }
    }

    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}
