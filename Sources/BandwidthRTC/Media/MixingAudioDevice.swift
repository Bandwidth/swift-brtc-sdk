import AVFoundation
import WebRTC

/// Simplified RTCAudioDevice for capturing mic audio and playing remote audio.
///
/// Recording path:
///   - Mic tap → deliver directly to WebRTC + visualization callback
///
/// Playout path:
///   - AVAudioSourceNode render callback pulls Int16 PCM from WebRTC via getPlayoutData, converts to Float32
public final class MixingAudioDevice: NSObject, RTCAudioDevice {

    // MARK: - Configuration

    private let audioOptions: AudioProcessingOptions

    /// Precomputed reciprocal so the render callback does a multiply instead of a divide.
    private static let int16ToFloat: Float32 = 1.0 / Float32(Int16.max)

    // MARK: - Logger

    private let log = Logger.shared

    // MARK: - WebRTC delegate

    private weak var delegate: (any RTCAudioDeviceDelegate)?
    private let audioQueue = DispatchQueue(label: "com.bandwidth.mixingaudio", qos: .userInteractive)

    // MARK: - AVAudioEngine

    public private(set) var engine = AVAudioEngine()
    public private(set) var sourceNode: AVAudioSourceNode?
    private var micConverter: AVAudioConverter?

    // MARK: - Init

    public init(audioOptions: AudioProcessingOptions = AudioProcessingOptions()) {
        self.audioOptions = audioOptions
        super.init()
    }

    // MARK: - Audio level callbacks

    /// Called with Float32 samples for visualization after each mic capture.
    public var onLocalAudioLevel: (([Float32]) -> Void)?

    /// Called with Float32 samples for visualization after each remote audio playout chunk.
    public var onRemoteAudioLevel: (([Float32]) -> Void)?

    // MARK: - Engine configuration change observer

    private var engineConfigObserver: NSObjectProtocol?

    // MARK: - Timestamp tracking

    private var recordSampleTime: Double = 0
    private var playoutSampleTime: Double = 0

    // MARK: - Render thread buffers (pre-allocated to avoid heap alloc on real-time thread)

    private var playoutInt16Buf  = [Int16](repeating: 0, count: 960)
    private var recordInt16Buf   = [Int16](repeating: 0, count: 960)
    private var micFloat32Buf    = [Float32](repeating: 0, count: 960)
    /// Pre-allocated mono mix buffer for the remote playout tap — avoids per-cycle heap allocation.
    private var remoteFloat32Buf = [Float32](repeating: 0, count: 960)
    /// Pre-allocated output buffer for mic sample-rate conversion — avoids per-cycle allocation.
    private var micConversionBuf: AVAudioPCMBuffer?

    // MARK: - RTCAudioDevice: State

    public private(set) var isInitialized: Bool = false
    public private(set) var isPlayoutInitialized: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var isRecordingInitialized: Bool = false
    public private(set) var isRecording: Bool = false

    // MARK: - RTCAudioDevice: Format

    public var deviceInputSampleRate: Double { audioOptions.inputSampleRate }
    public var inputIOBufferDuration: TimeInterval { audioOptions.preferredIOBufferDuration ?? (audioOptions.useLowLatency ? 0.005 : 0.01) }
    public var inputNumberOfChannels: Int { audioOptions.inputChannels }
    public var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }

    public var deviceOutputSampleRate: Double { audioOptions.outputSampleRate }
    public var outputIOBufferDuration: TimeInterval { audioOptions.preferredIOBufferDuration ?? (audioOptions.useLowLatency ? 0.005 : 0.01) }
    public var outputNumberOfChannels: Int { audioOptions.outputChannels }
    public var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    // MARK: - RTCAudioDevice: Lifecycle

    public func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: audioOptions.audioSessionMode, options: audioOptions.audioSessionCategoryOptions)
            let ioDuration = audioOptions.preferredIOBufferDuration ?? (audioOptions.useLowLatency ? 0.005 : 0.01)
            try session.setPreferredIOBufferDuration(ioDuration)
            try session.setActive(true)
        } catch {
            log.error("AVAudioSession config failed: \(error)")
        }
        setupSourceNode()                   // attach before engine starts → no mid-run reconfig
        setupEngineConfigurationObserver()  // safety net for real-device route changes
        isInitialized = true
        log.debug("AudioDevice initialized")
        return true
    }

    public func terminateDevice() -> Bool {
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        if engine.isRunning { engine.stop() }
        micConverter = nil
        micConversionBuf = nil
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

    public func initializePlayout() -> Bool {
        isPlayoutInitialized = true
        log.debug("Playout initialized")
        return true
    }

    public func startPlayout() -> Bool {
        isPlaying = true
        startEngineIfNeeded()
        installPlayoutTap()
        log.debug("Playout started")
        return true
    }

    public func stopPlayout() -> Bool {
        isPlaying = false
        engine.mainMixerNode.removeTap(onBus: 0)
        log.debug("Playout stopped")
        return true
    }

    // MARK: - RTCAudioDevice: Recording

    public func initializeRecording() -> Bool {
        installMicTap()
        isRecordingInitialized = true
        log.debug("Recording initialized")
        return true
    }

    public func startRecording() -> Bool {
        isRecording = true
        startEngineIfNeeded()
        log.debug("Recording started")
        return true
    }

    public func stopRecording() -> Bool {
        isRecording = false
        log.debug("Recording stopped")
        return true
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
        // Remove stale taps before restarting to avoid double-tap overload
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        // Reattach source node and reconfig converters since the hardware format may have changed
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        micConverter = nil
        micConversionBuf = nil
        setupSourceNode()
        startEngineIfNeeded()
        if isRecording {
            installMicTap()
        }
        if isPlaying {
            installPlayoutTap()
        }
    }

    private func setupSourceNode() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioOptions.outputSampleRate,
            channels: AVAudioChannelCount(audioOptions.outputChannels),
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
            let scale = MixingAudioDevice.int16ToFloat
            for i in 0..<count {
                outPtr[i] = Float32(self.playoutInt16Buf[i]) * scale
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
        mixerNode.removeTap(onBus: 0)  // clear any stale tap before installing
        let format = mixerNode.outputFormat(forBus: 0)
        mixerNode.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            guard let self, let floatData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            // Grow pre-allocated buffer only if needed — no heap alloc on the hot path
            if count > self.remoteFloat32Buf.count {
                self.remoteFloat32Buf = [Float32](repeating: 0, count: count)
            }
            for i in 0..<count {
                var s: Float = 0
                for ch in 0..<channelCount { s += floatData[ch][i] }
                self.remoteFloat32Buf[i] = max(-1.0, min(1.0, s / Float(max(1, channelCount))))
            }
            // Copy only what we need before hopping to the main queue
            let samples = Array(self.remoteFloat32Buf[0..<count])
            // Dispatch off the real-time audio thread before invoking app-level callback
            DispatchQueue.main.async { [weak self] in
                self?.onRemoteAudioLevel?(samples)
            }
        }
    }

    /// Install a tap on the input node to capture mic audio directly.
    /// Mic audio is processed inline: deliver to WebRTC + visualization.
    private func installMicTap() {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioOptions.inputSampleRate,
            channels: AVAudioChannelCount(audioOptions.inputChannels),
            interleaved: false
        )!

        if nativeFormat.sampleRate != audioOptions.inputSampleRate || nativeFormat.channelCount != AVAudioChannelCount(audioOptions.inputChannels) {
            micConverter = AVAudioConverter(from: nativeFormat, to: targetFormat)
            // Pre-allocate the output buffer for conversion — avoids per-callback heap allocation.
            // Use 4× the tap bufferSize as capacity to absorb any engine-side buffer variance.
            let ratio = audioOptions.inputSampleRate / nativeFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(4096) * ratio) + 1
            micConversionBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let converted: AVAudioPCMBuffer
            if let conv = self.micConverter, let out = self.micConversionBuf {
                out.frameLength = 0  // reset before reuse
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

        // Grow pre-allocated buffer only if needed — no heap alloc on the hot path
        if count > micFloat32Buf.count {
            micFloat32Buf = [Float32](repeating: 0, count: count)
        }

        for i in 0..<count {
            var sample: Float = 0
            for ch in 0..<channels { sample += floatData[ch][i] }
            micFloat32Buf[i] = max(-1.0, min(1.0, sample / Float(channels)))
        }

        deliverSamplesToWebRTC(count: count)
        // Copy only what we need before hopping to the main queue
        let samples = Array(micFloat32Buf[0..<count])
        DispatchQueue.main.async { [weak self] in
            self?.onLocalAudioLevel?(samples)
        }
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

    // MARK: - Private: Deliver Samples to WebRTC

    /// Convert `micFloat32Buf[0..<count]` to Int16 and deliver to WebRTC.
    /// Caller must have already written `count` valid samples into `micFloat32Buf`.
    private func deliverSamplesToWebRTC(count: Int) {
        guard let delegate else { return }

        if count > recordInt16Buf.count {
            recordInt16Buf = [Int16](repeating: 0, count: count)
        }
        let int16Max = Float(Int16.max)
        for i in 0..<count {
            recordInt16Buf[i] = Int16(micFloat32Buf[i] * int16Max)
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
