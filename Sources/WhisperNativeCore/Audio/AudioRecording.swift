import Foundation

@MainActor
public protocol AudioRecording: AnyObject {
    /// Starts writing the mic to `path`. While listening, the mic is already
    /// open: recording begins at once, with the last `Constants.voiceStartPreRoll`
    /// seconds of listened audio first when `includePreRoll` is set.
    func startRecording(to path: URL, includePreRoll: Bool) async throws
    func stopRecording() async throws -> URL
    /// Opens the mic without recording, handing every PCM buffer to `onAudio`
    /// (on CoreAudio's IO thread; it must not block). Needs the microphone
    /// grant already given: it never prompts.
    func startListening(onAudio: @escaping @Sendable (Data) -> Void) throws
    func stopListening()
    /// Sets up voice processing ahead of the next recording while
    /// `voiceProcessingEnabled`, and releases it otherwise. Never prompts.
    func prepareVoiceProcessing()
    var isRecording: Bool { get }
    var isListening: Bool { get }
    var onRecordingFailed: (@Sendable (AppError) -> Void)? { get set }
    var pcmSink: (@Sendable (Data) -> Void)? { get set }
    var preferredInputDeviceUID: String? { get set }
    var voiceProcessingEnabled: Bool { get set }
    var soundFeedbackEnabled: Bool { get set }
    var soundVolume: Float { get set }
    var recordingTimeoutSeconds: Int { get set }
}

public extension AudioRecording {
    func startRecording(to path: URL) async throws {
        try await startRecording(to: path, includePreRoll: false)
    }
}
