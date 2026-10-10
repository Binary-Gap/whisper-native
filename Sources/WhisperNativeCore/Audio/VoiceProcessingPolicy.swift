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

/// One of the two settings that are never on together.
public enum ExclusiveMicSetting: Equatable, Sendable {
    case voiceProcessing
    case startOnVoice
}

/// Decides when the mic runs through macOS voice processing
/// (`Config.voiceProcessing`). Voice processing and Start on voice are never
/// on together: while voice processing is enabled in this process, macOS
/// hands every other capture of the mic, Start on voice listening included,
/// raw audio ~100x quieter, so speech would never be detected.
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

    /// `current` with at most one of voice processing and Start on voice on,
    /// plus the setting turned off to get there. The one just turned on wins;
    /// with both already on (a config saved by an older version), Start on
    /// voice stays.
    public static func resolveExclusive(previous: Config, current: Config) -> (config: Config, turnedOff: ExclusiveMicSetting?) {
        guard current.voiceProcessing, current.startOnVoice else { return (current, nil) }
        var resolved = current
        if previous.voiceProcessing {
            resolved.voiceProcessing = false
            return (resolved, .voiceProcessing)
        }
        resolved.startOnVoice = false
        return (resolved, .startOnVoice)
    }

    /// Visible status line under the setting `resolveExclusive` turned off.
    public static func turnedOffNote(_ setting: ExclusiveMicSetting) -> String {
        switch setting {
        case .voiceProcessing:
            return "Turned off because auto-start when you speak is on: the two can't run together."
        case .startOnVoice:
            return "Turned off because voice processing is on: the two can't run together."
        }
    }
}
