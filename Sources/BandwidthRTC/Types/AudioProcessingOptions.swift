import AVFoundation

/// Audio processing and format configuration for a BRTC session.
///
/// Pass this inside `RtcOptions.audioProcessing` when calling `connect()`.
/// All fields are optional — defaults match the SDK's previous hard-coded behaviour.
public struct AudioProcessingOptions: Sendable {

    // MARK: - AVAudioSession mode / hardware processing

    /// AVAudioSession mode used when initializing the audio device.
    /// `.voiceChat` (default) enables Apple's hardware AEC and noise suppression.
    /// Set to `.default` or `.measurement` to disable hardware processing.
    public var audioSessionMode: AVAudioSession.Mode

    /// AVAudioSession category options (e.g. `.allowBluetoothHFP`, `.defaultToSpeaker`).
    public var audioSessionCategoryOptions: AVAudioSession.CategoryOptions

    // MARK: - Sample rate / channel count

    /// Input (recording) sample rate in Hz. Defaults to 48 000 (WebRTC Opus rate).
    /// WebRTC's internal resampler handles mismatches, but 48 kHz avoids a conversion step.
    public var inputSampleRate: Double

    /// Output (playout) sample rate in Hz. Defaults to 48 000.
    public var outputSampleRate: Double

    /// Number of input channels. Defaults to 1 (mono).
    public var inputChannels: Int

    /// Number of output channels. Defaults to 1 (mono).
    public var outputChannels: Int

    // MARK: - Buffer / latency

    /// Request low-latency I/O from AVAudioSession (sets preferred I/O buffer duration to 5 ms).
    /// Reduces latency at the cost of higher CPU usage. Defaults to `false`.
    public var useLowLatency: Bool

    /// Preferred I/O buffer duration in seconds. Overrides `useLowLatency` when non-nil.
    /// The OS rounds this to the nearest supported value.
    public var preferredIOBufferDuration: TimeInterval?

    // MARK: - Init

    public init(
        audioSessionMode: AVAudioSession.Mode = .voiceChat,
        audioSessionCategoryOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP],
        inputSampleRate: Double = 48000,
        outputSampleRate: Double = 48000,
        inputChannels: Int = 1,
        outputChannels: Int = 1,
        useLowLatency: Bool = false,
        preferredIOBufferDuration: TimeInterval? = nil
    ) {
        self.audioSessionMode = audioSessionMode
        self.audioSessionCategoryOptions = audioSessionCategoryOptions
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.useLowLatency = useLowLatency
        self.preferredIOBufferDuration = preferredIOBufferDuration
    }
}
