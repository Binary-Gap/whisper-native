import Foundation

/// How Settings shows the recording timeout and when it warns about it.
public enum RecordingTimeoutFormat {
    /// Longest recording Gemini after recording (batch) accepts (~7 min of
    /// 16 kHz mono 16-bit WAV in a 20 MB inline request).
    public static let geminiBatchLimitSeconds = 420

    /// "45 s", "2 min", "1 min 30 s".
    public static func label(seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes == 0 { return "\(rest) s" }
        if rest == 0 { return "\(minutes) min" }
        return "\(minutes) min \(rest) s"
    }

    /// Warning shown while Gemini after recording is the engine and the timeout
    /// lets a recording outgrow what it accepts; nil otherwise.
    public static func geminiBatchWarning(seconds: Int, engine: TranscriptionEngine) -> String? {
        guard engine == .gemini, seconds > geminiBatchLimitSeconds else { return nil }
        return "Gemini after recording accepts up to ~7 min per dictation, so a longer recording fails to transcribe."
    }
}
