import Foundation

/// How a recording gets its mic audio when it starts.
public enum RecordingCapture: Equatable, Sendable {
    /// Keep the capture that is already listening (Start on voice): the mic
    /// stays warm and the pre-roll survives. Listening is always unprocessed.
    case continueListening
    /// Open a new capture, through macOS voice processing (noise suppression
    /// and automatic gain) when `voiceProcessed` is set. A listening capture
    /// closes first.
    case open(voiceProcessed: Bool)
}

/// Decides when the mic runs through macOS voice processing
/// (`Config.voiceProcessing`). Listening for Start on voice always uses the
/// unprocessed mic: voice processing lowers other apps' audio for as long as
/// it runs, which would last the whole idle time, and the speech onset gate
/// is tuned on raw levels that automatic gain would keep moving. So a
/// dictation that starts from voice keeps the unprocessed capture (with its
/// pre-roll), while a hotkey press during listening reopens the mic processed.
public enum VoiceProcessingPolicy {
    public static func recordingCapture(
        voiceProcessing: Bool,
        isListening: Bool,
        includePreRoll: Bool
    ) -> RecordingCapture {
        guard isListening else { return .open(voiceProcessed: voiceProcessing) }
        if includePreRoll || !voiceProcessing { return .continueListening }
        return .open(voiceProcessed: true)
    }

    /// Visible note under the Voice processing toggle while both it and
    /// Start on voice are on, nil otherwise.
    public static func startOnVoiceNote(voiceProcessing: Bool, startOnVoice: Bool) -> String? {
        guard voiceProcessing, startOnVoice else { return nil }
        return "Dictations started by your voice use the unprocessed mic; hotkey dictations are processed."
    }
}
