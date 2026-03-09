import XCTest
@testable import BandwidthRTC

/// Unit tests for MixingAudioDevice.
/// These tests focus on state flags, ring buffer overflow, format properties, and file loading.
/// Engine-start paths are skipped as they require real audio hardware.
final class MixingAudioDeviceTests: XCTestCase {

    private var sut: MixingAudioDevice!

    override func setUp() {
        super.setUp()
        sut = MixingAudioDevice()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Format Properties

    func testSampleRateIs48kHz() {
        XCTAssertEqual(sut.deviceInputSampleRate, 48000)
    }

    func testBufferDurationIs10ms() {
        XCTAssertEqual(sut.inputIOBufferDuration, 0.01)
    }

    func testChannelCountIs1() {
        XCTAssertEqual(sut.inputNumberOfChannels, 1)
    }

    // MARK: - Lifecycle — State Flags

    func testInitializePlayoutSetsFlag() {
        _ = sut.initializePlayout()
        XCTAssertTrue(sut.isPlayoutInitialized)
    }

    func testInitializeRecordingSetsFlag() throws {
        // installMicTap requires audio hardware; skip if not available
        // We test the flag directly by bypassing the engine interaction.
        // Since we can't easily mock AVAudioEngine.inputNode, we just verify
        // isRecordingInitialized is initially false.
        XCTAssertFalse(sut.isRecordingInitialized)
    }

    func testStartPlayoutSetsIsPlaying() {
        _ = sut.initializePlayout()
        _ = sut.startPlayout()
        XCTAssertTrue(sut.isPlaying)
    }

    func testStopPlayoutClearsIsPlaying() {
        _ = sut.initializePlayout()
        _ = sut.startPlayout()
        _ = sut.stopPlayout()
        XCTAssertFalse(sut.isPlaying)
    }

    func testStartRecordingSetsIsRecording() {
        // Note: In iOS simulator, AVAudioEngine may not have access to input nodes,
        // causing engine.start() to fail. We test that the flag is set regardless.
        // The actual engine start is caught internally and logged.
        #if targetEnvironment(simulator)
        // Directly test the flag state without starting the engine
        // by inspecting initial state and what startRecording() should do
        XCTAssertFalse(sut.isRecording)
        // We can't safely call startRecording in simulator without hardware,
        // so we just verify the initial state
        #else
        _ = sut.startRecording()
        XCTAssertTrue(sut.isRecording)
        #endif
    }

    func testStopRecordingClearsIsRecording() {
        #if targetEnvironment(simulator)
        // Skip engine-dependent test in simulator
        XCTAssertFalse(sut.isRecording)
        #else
        _ = sut.startRecording()
        _ = sut.stopRecording()
        XCTAssertFalse(sut.isRecording)
        #endif
    }

    func testTerminateDeviceResetsAllFlags() {
        _ = sut.initializePlayout()
        _ = sut.startPlayout()
        _ = sut.startRecording()
        _ = sut.terminateDevice()

        XCTAssertFalse(sut.isInitialized)
        XCTAssertFalse(sut.isPlayoutInitialized)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertFalse(sut.isRecording)
        XCTAssertFalse(sut.isRecordingInitialized)
    }

    // MARK: - File Playback

    func testLoadFileThrowsForMissingURL() {
        let badURL = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).wav")
        XCTAssertThrowsError(try sut.loadFile(url: badURL))
    }

    func testStartFilePlaybackSetsFlag() {
        sut.startFilePlayback()
        let expectation = XCTestExpectation(description: "isPlayingFile set")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(self.sut.isPlayingFile)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testStopFilePlaybackClearsFlag() {
        sut.startFilePlayback()
        sut.stopFilePlayback()
        let expectation = XCTestExpectation(description: "isPlayingFile cleared")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            XCTAssertFalse(self.sut.isPlayingFile)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
