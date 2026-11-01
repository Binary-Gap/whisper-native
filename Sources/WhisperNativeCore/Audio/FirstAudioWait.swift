import Foundation

/// Waits for a capture that just started to deliver its first audio. Voice
/// processing can start without an error and still never deliver a buffer
/// (macOS's voice-processing unit stuck system-wide), so the recorder holds
/// the start cue on this and opens the unprocessed mic when it times out.
public enum FirstAudioWait {
    /// Time until `hasAudio` returned true, polled every `pollInterval`, or nil
    /// when it stayed false for `timeout` (or the task was cancelled).
    public static func wait(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(10),
        hasAudio: @Sendable () -> Bool
    ) async -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if hasAudio() { return clock.now - start }
            if clock.now - start >= timeout || Task.isCancelled { return nil }
            try? await Task.sleep(for: pollInterval)
        }
    }
}

extension Duration {
    /// Whole milliseconds, for log lines.
    var milliseconds: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
