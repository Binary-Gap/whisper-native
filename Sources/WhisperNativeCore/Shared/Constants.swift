import Foundation

public enum Constants {
    public static let serverHost = "127.0.0.1"
    public static let serverPort = 8080

    private static let serverBaseURLString = "http://\(serverHost):\(serverPort)"
    public static let serverHealthURL = URL(string: "\(serverBaseURLString)/health")!
    public static let serverInferenceURL = URL(string: "\(serverBaseURLString)/inference")!
    public static let serverLoadURL = URL(string: "\(serverBaseURLString)/load")!

    public static let tempDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("whisper-native/tmp", isDirectory: true)
    }()

    // Stable store for recordings that back history entries. Files here persist
    // (revealed/played from the History view), unlike the tmp scratch directory.
    public static let historyDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("whisper-native/history", isDirectory: true)
    }()

    public static let historyMetadataURL: URL = {
        historyDirectory.appendingPathComponent("history.json", isDirectory: false)
    }()

    public static let logDirectory: URL = {
        let logsBase = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return logsBase.appendingPathComponent("whisper-native", isDirectory: true)
    }()

    // App-owned models directory. whisper-native downloads/scans .bin models here
    // by default; the user can point Settings at a different folder.
    public static let defaultModelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("whisper-native/models", isDirectory: true)
    }()

    // Default model filenames downloaded on first run. The whisper model uses the
    // canonical ggml name; the VAD model is silero (whisper.cpp's bundled VAD).
    public static let defaultModelFileName = "ggml-large-v3-turbo.bin"
    public static let defaultVadModelFileName = "ggml-silero-v6.2.0.bin"

    // HuggingFace download URLs seeded on first run.
    public static let whisperModelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(defaultModelFileName)?download=true")!
    public static let vadModelDownloadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(defaultVadModelFileName)?download=true")!

    public static var defaultModelPath: URL {
        defaultModelsDirectory.appendingPathComponent(defaultModelFileName)
    }
    public static var defaultVadModelPath: URL {
        defaultModelsDirectory.appendingPathComponent(defaultVadModelFileName)
    }

    public static let whisperServerLaunchdLabel = "io.binarygap.whisper-server"

    public static let whisperServerPlistPath: URL = {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return libraryDir.appendingPathComponent("LaunchAgents/io.binarygap.whisper-server.plist")
    }()

    /// Wraps a transcript in the audio-tag markers used across all insertion destinations.
    public static func wrapWithAudioTags(_ text: String) -> String {
        "<audio>\n\(text)\n</audio>"
    }

    // After CoreAudio capture starts, the mic hardware needs a moment to settle
    // before it delivers full-level audio. Waiting this long before playing the
    // record cue means the user speaks into an already-warm mic, so the first
    // word isn't recorded into the low-level warmup ramp.
    public static let micWarmupDelay: TimeInterval = 0.25

    public static let recordingStartTimeout: TimeInterval = 5
    public static let recordingStopFallbackTimeout: TimeInterval = 3
    public static let recordingTimeoutSeconds = 300
    public static let maxHistoryItems = 50
    public static let minValidAudioBytes = 1000

    public static let voiceCalibrationSamplePath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("whisper-native/voice-calibration-sample.wav")
    }()

    // Recordings at or above this duration already give whisper enough acoustic
    // context on their own; prepending the calibration sample would only add
    // latency for no accuracy benefit.
    public static let voiceCalibrationSkipDuration: TimeInterval = 20.0

    // Calibration samples auto-stop at this length; the suggested reading
    // prompt fits comfortably within it.
    public static let voiceCalibrationMaxDuration: TimeInterval = 20.0

    // Appended after recording stops; compensates for VAD clipping the last
    // word right at the recording boundary, so the anchor phrase at the end of
    // the calibration sample survives into the transcript.
    public static let voiceCalibrationTrailingSilence: TimeInterval = 3.0

    // Fixed phrase the user reads at the END of the calibration sample. It marks
    // the boundary between the calibration audio and real dictation: on output,
    // everything up to and including this phrase is calibration and is stripped.
    // Anchor matching is fuzzy (edit-distance tolerant), so a mis-transcribed
    // word like "End of" -> "and of" still matches, and it stays robust to VAD
    // timestamp compression and re-segmentation, unlike matching the whole sample
    // text or cutting by timestamp.
    public static let voiceCalibrationAnchorPhrase = "end of calibration sample"

    // Whisper cannot follow instructions; it only continues text. These are
    // example-style exemplars whose punctuation and capitalization the model
    // imitates. User's config.prompt (a natural transcript sentence with
    // domain terms) is appended to bias vocabulary further.
    public static let languagePrompts: [Language: String] = [
        .english: "Let's refactor the API client and add a unit test. Run the build, check the git diff, then commit and open a pull request.",
        .portuguese: "Vamos refatorar o API client e adicionar um unit test. Roda o build, confere o git diff, depois faz o commit e abre o pull request.",
        .auto: "",
    ]
}
