import Foundation

/// Which engines produce a transcript while the user is still talking. Features
/// that react to the live transcript (saying a stop word to stop) work only
/// with these.
extension TranscriptionEngine {
    /// Parakeet (periodic previews) and Gemini Live (interim events) transcribe
    /// during the recording; whisper and batch Gemini transcribe after it ends.
    public var hasLiveTranscript: Bool {
        switch self {
        case .parakeet, .geminiLive: true
        case .whisper, .gemini: false
        }
    }

    /// Engines named in the UI when a live-transcript feature is unavailable.
    public static let liveTranscriptEngineNames = "Parakeet and Gemini Live"

    /// Why "Say a stop word to stop" can't be used with this engine, nil when
    /// it can.
    public var stopWordUnavailableReason: String? {
        hasLiveTranscript
            ? nil
            : "Works only with \(Self.liveTranscriptEngineNames), which transcribe while you talk. \(shortName) transcribes after you stop."
    }

    private var shortName: String {
        switch self {
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        case .gemini: "Gemini (after recording)"
        case .geminiLive: "Gemini Live"
        }
    }
}
