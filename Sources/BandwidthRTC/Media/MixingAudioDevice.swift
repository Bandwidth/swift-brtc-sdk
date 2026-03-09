import AVFoundation
import WebRTC

/// Simplified RTCAudioDevice for capturing mic audio and playing remote audio.
///
/// Recording path:
///   - Normal mode: Mic tap → deliver directly to WebRTC + visualization callback
///   - File mode: Timer reads from resampled PCM buffer → WebRTC + visualization callback
///
/// Playout path:
///   - AVAudioSourceNode render callback pulls Int16 PCM from WebRTC via getPlayoutData, converts to Float32
final class MixingAudioDevice: NSObject, RTCAudioDevice {

    // MARK: - Constants

    private static let sampleRate: Double = 48000
    private static let framesPerChunk: Int = 480     // 10 ms at 48 kHz

    // MARK: - Logger

    private let log = Logger.shared

    // MARK: - WebRTC delegate

    private weak var delegate: (any RTCAudioDeviceDelegate)?
    private let audioQueue = DispatchQueue(label: "com.bandwidth.mixingaudio", qos: .userInteractive)

    // MARK: - AVAudioEngine

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var micConverter: AVAudioConverter?

    // MARK: - File audio (for file playback mode)

    private var filePCMBuffer: AVAudioPCMBuffer?
    private var fileReadPos: Int = 0
    private(set) var isPlayingFile: Bool = false

    // MARK: - Audio level callbacks

    /// Called with Float32 samples for visualization after each mic capture or file chunk.
    var onLocalAudioLevel: (([Float32]) -> Void)?

    /// Called with Float32 samples for visualization after each remote audio playout chunk.
    var onRemoteAudioLevel: (([Float32]) -> Void)?

    // MARK: - Engine configuration change observer

    private var engineConfigObserver: NSObjectProtocol?

    // MARK: - Timers

    private var filePlaybackTimer: DispatchSourceTimer?

    // MARK: - Timestamp tracking

    private var recordSampleTime: Double = 0
    private var playoutSampleTime: Double = 0

    // MARK: - Render thread buffers (pre-allocated to avoid heap alloc on real-time thread)

    private var playoutInt16Buf = [Int16](repeating: 0, count: MixingAudioDevice.framesPerChunk * 2)
    private var recordInt16Buf  = [Int16](repeating: 0, count: MixingAudioDevice.framesPerChunk * 2)

    // MARK: - RTCAudioDevice: State

    private(set) var isInitialized: Bool = false
    private(set) var isPlayoutInitialized: Bool = false
    private(set) var isPlaying: Bool = false
    private(set) var isRecordingInitialized: Bool = false
    private(set) var isRecording: Bool = false

    // MARK: - RTCAudioDevice: Format

    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }

    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    // MARK: - RTCAudioDevice: Lifecycle

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        configureAudioSession()
        setupSourceNode()                   // attach before engine starts → no mid-run reconfig
        setupEngineConfigurationObserver()  // safety net for real-device route changes
        isInitialized = true
        log.debug("AudioDevice initialized")
        return true
    }

    func terminateDevice() -> Bool {
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        stopFilePlaybackTimer()
        engine.inputNode.removeTap(onBus: 0)
        removePlayoutTap()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        if engine.isRunning { engine.stop() }
        micConverter = nil
        delegate = nil
        isInitialized = false
        isPlayoutInitialized = false
        isRecordingInitialized = false
        isPlaying = false
        isRecording = false
        log.debug("AudioDevice terminated")
        return true
    }

    // MARK: - RTCAudioDevice: Playout

    func initializePlayout() -> Bool {
        isPlayoutInitialized = true
        log.debug("Playout initialized")
        return true
    }

    func startPlayout() -> Bool {
        isPlaying = true
        startEngineIfNeeded()
        installPlayoutTap()
        log.debug("Playout started")
        return true
    }

    func stopPlayout() -> Bool {
        isPlaying = false
        removePlayoutTap()
        log.debug("Playout stopped")
        return true
    }

    // MARK: - RTCAudioDevice: Recording

    func initializeRecording() -> Bool {
        installMicTap()
        isRecordingInitialized = true
        log.debug("Recording initialized")
        return true
    }

    func startRecording() -> Bool {
        isRecording = true
        startEngineIfNeeded()
        log.debug("Recording started")
        return true
    }

    func stopRecording() -> Bool {
        isRecording = false
        log.debug("Recording stopped")
        return true
    }

    // MARK: - File Playback Control

    /// Load and resample an audio file to 48 kHz mono Float32.
    func loadFile(url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let sourceFrameCount = AVAudioFrameCount(audioFile.length)
        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: sourceFrameCount
        )!
        try audioFile.read(into: sourceBuffer)
        sourceBuffer.frameLength = sourceFrameCount

        let srcFormat = audioFile.processingFormat
        let converted: AVAudioPCMBuffer
        if srcFormat.sampleRate == Self.sampleRate,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32
        {
            converted = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
                log.error("Cannot create converter for \(srcFormat)")
                throw NSError(
                    domain: "MixingAudioDevice",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot create AVAudioConverter for file"]
                )
            }
            let ratio = Self.sampleRate / srcFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(sourceFrameCount) * ratio) + 1
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)!
            var convertError: NSError?
            var inputProvided = false
            converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
                if inputProvided { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                inputProvided = true
                return sourceBuffer
            }
            if let err = convertError { throw err }
            converted = outputBuffer
        }

        audioQueue.sync {
            self.filePCMBuffer = converted
            self.fileReadPos = 0
        }
        log.debug("File loaded: \(url.lastPathComponent), \(converted.frameLength) frames at 48kHz")
    }

    func startFilePlayback() {
        audioQueue.async {
            self.isPlayingFile = true
            self.startFilePlaybackTimer()
            self.log.debug("File playback started")
        }
    }

    func stopFilePlayback() {
        audioQueue.async {
            self.isPlayingFile = false
            self.fileReadPos = 0
            self.stopFilePlaybackTimer()
            self.log.debug("File playback stopped")
        }
    }

    // MARK: - Private: Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            log.error("AVAudioSession config failed: \(error)")
        }
    }

    // MARK: - Private: AVAudioEngine Setup

    /// Subscribe to AVAudioEngineConfigurationChange so we can recover when the simulator (or device)
    /// drops its I/O cycle after a mid-run node attachment.
    private func setupEngineConfigurationObserver() {
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    /// Called when the audio hardware is reconfigured.
    /// The engine's I/O cycle may have been abandoned; force a stop/restart to restore it.
    private func handleEngineConfigurationChange() {
        log.warn("[BRTC] AVAudioEngineConfigurationChange — restarting engine")
        engine.stop()
        startEngineIfNeeded()
        if isPlaying {
            installPlayoutTap()
        }
    }

    private func setupSourceNode() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self, let delegate = self.delegate else {
                // Fill silence if no delegate
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                if let ptr = abl[0].mData?.assumingMemoryBound(to: Float32.self) {
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                }
                return noErr
            }

            let count = Int(frameCount)

            // Pull Int16 samples directly from WebRTC
            // Reuse pre-allocated buffer (resizing only if frameCount exceeds capacity)
            if count > self.playoutInt16Buf.count {
                self.playoutInt16Buf = [Int16](repeating: 0, count: count)
            }
            self.playoutInt16Buf.withUnsafeMutableBytes { rawBytes in
                var audioBuffer = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(count * MemoryLayout<Int16>.size),
                    mData: rawBytes.baseAddress
                )
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                var flags: AudioUnitRenderActionFlags = []
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = self.playoutSampleTime
                timestamp.mFlags = .sampleTimeValid

                _ = delegate.getPlayoutData(
                    &flags, &timestamp, 0, UInt32(count), &bufferList
                )
                self.playoutSampleTime += Double(count)
            }

            // Convert Int16 → Float32 into the output buffer
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let outPtr = abl[0].mData?.assumingMemoryBound(to: Float32.self) else { return noErr }
            for i in 0..<count {
                outPtr[i] = Float32(self.playoutInt16Buf[i]) / Float32(Int16.max)
            }

            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    /// Install a tap on the main mixer output to capture remote playout audio for visualization.
    private func installPlayoutTap() {
        let mixerNode = engine.mainMixerNode
        mixerNode.removeTap(onBus: 0)
        let format = mixerNode.outputFormat(forBus: 0)
        mixerNode.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            guard let self, let floatData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var mono = [Float32](repeating: 0, count: count)
            for i in 0..<count {
                var s: Float = 0
                for ch in 0..<channelCount { s += floatData[ch][i] }
                mono[i] = max(-1.0, min(1.0, s / Float(max(1, channelCount))))
            }
            self.onRemoteAudioLevel?(mono)
        }
    }

    private func removePlayoutTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    /// Install a tap on the input node to capture mic audio directly.
    /// Mic audio is processed inline: deliver to WebRTC + visualization.
    private func installMicTap() {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        if nativeFormat.sampleRate != Self.sampleRate || nativeFormat.channelCount != 1 {
            micConverter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self, !self.isPlayingFile else { return }

            let converted: AVAudioPCMBuffer
            if let conv = self.micConverter {
                let ratio = Self.sampleRate / nativeFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)!
                var convError: NSError?
                var consumed = false
                conv.convert(to: out, error: &convError) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    status.pointee = .haveData
                    consumed = true
                    return buffer
                }
                if convError != nil { return }
                converted = out
            } else {
                converted = buffer
            }

            self.deliverMicAudio(converted)
        }
    }

    /// Mix channels, deliver Float32 samples to WebRTC, and invoke visualization callback.
    private func deliverMicAudio(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var float32Samples = [Float32](repeating: 0, count: count)

        for i in 0..<count {
            var sample: Float = 0
            for ch in 0..<channels { sample += floatData[ch][i] }
            float32Samples[i] = max(-1.0, min(1.0, sample / Float(channels)))
        }

        deliverSamplesToWebRTC(float32Samples)
        onLocalAudioLevel?(float32Samples)
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("AVAudioEngine start failed: \(error)")
        }
    }

    // MARK: - Private: File Playback Timer

    private func startFilePlaybackTimer() {
        guard filePlaybackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.deliverFileChunk() }
        timer.resume()
        filePlaybackTimer = timer
    }

    private func stopFilePlaybackTimer() {
        filePlaybackTimer?.cancel()
        filePlaybackTimer = nil
    }

    private func deliverFileChunk() {
        guard let buf = filePCMBuffer, let floatData = buf.floatChannelData else { return }

        let total = Int(buf.frameLength)
        if fileReadPos >= total {
            log.debug("File looped")
            fileReadPos = 0
        }

        let frames = min(Self.framesPerChunk, total - fileReadPos)
        var float32Samples = [Float32](repeating: 0, count: Self.framesPerChunk)

        let src = floatData[0] + fileReadPos
        for i in 0..<frames {
            float32Samples[i] = max(-1.0, min(1.0, src[i]))
        }
        fileReadPos += frames

        deliverSamplesToWebRTC(float32Samples)
        onLocalAudioLevel?(float32Samples)
    }

    // MARK: - Private: Deliver Samples to WebRTC

    private func deliverSamplesToWebRTC(_ samples: [Float32]) {
        guard let delegate else { return }

        let count = samples.count
        if count > recordInt16Buf.count {
            recordInt16Buf = [Int16](repeating: 0, count: count)
        }
        for i in 0..<count {
            recordInt16Buf[i] = Int16(samples[i] * Float(Int16.max))
        }

        recordInt16Buf.withUnsafeMutableBytes { rawBytes in
            var audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(count * MemoryLayout<Int16>.size),
                mData: rawBytes.baseAddress
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = recordSampleTime
            timestamp.mFlags = .sampleTimeValid

            _ = delegate.deliverRecordedData(
                &flags, &timestamp, 0, UInt32(count), &bufferList, nil, nil
            )
            recordSampleTime += Double(count)
        }
    }
}
