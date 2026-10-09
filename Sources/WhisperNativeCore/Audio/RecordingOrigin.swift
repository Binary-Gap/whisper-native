import Foundation

/// What started the recording in progress.
public enum RecordingOrigin: Equatable, Sendable {
    /// The toggle dictation hotkey.
    case hotkey
    /// Start on voice detected speech on the listening mic.
    case voice

    /// Whether the recording gets cancelled (audio discarded, nothing
    /// transcribed or pasted) given the current Start on voice setting: turning
    /// the setting off cancels a recording it started, while a hotkey
    /// recording keeps going until the user ends it.
    public func isCancelled(startOnVoice: Bool) -> Bool {
        self == .voice && !startOnVoice
    }
}
