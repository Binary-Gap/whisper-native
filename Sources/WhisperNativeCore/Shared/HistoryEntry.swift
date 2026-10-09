import Foundation

/// One transcription run recorded for the History view: the audio file plus the
/// resulting text and metadata. Persisted as JSON via `TranscriptionHistoryStore`,
/// which keeps every entry as a usage log for debugging and model comparisons.
/// Only the newest entries keep their audio file.
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case failed
    }

    public let id: UUID
    public var timestamp: Date
    /// Absolute file URL into `Constants.historyDirectory`. Missing on disk once
    /// the entry ages out of the newest `Constants.maxHistoryAudioFiles` (the
    /// view greys out Play/Reveal/Rerun).
    public var audioFilePath: URL
    /// Empty string when the run failed or was not yet transcribed.
    public var text: String
    /// Language actually used for the run.
    public var language: Language
    /// `Config.selectedModelName` at run time.
    public var modelName: String
    public var status: Status
    /// Response time: transcription wall-time, when known.
    public var durationSeconds: Double?
    /// Length of the recorded audio, when known.
    public var audioDurationSeconds: Double?
    /// `GeminiLiveMode` raw value for Gemini Live runs, nil for every other
    /// engine. Stored as a string so an unknown mode never breaks decoding.
    public var transcriptionMode: String?
    /// Estimated USD of the run (`GeminiPricing`), set only for Gemini models;
    /// local engines are free and leave it nil.
    public var estimatedCostUSD: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        audioFilePath: URL,
        text: String,
        language: Language,
        modelName: String,
        status: Status,
        durationSeconds: Double? = nil,
        audioDurationSeconds: Double? = nil,
        transcriptionMode: String? = nil,
        estimatedCostUSD: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.audioFilePath = audioFilePath
        self.text = text
        self.language = language
        self.modelName = modelName
        self.status = status
        self.durationSeconds = durationSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptionMode = transcriptionMode
        self.estimatedCostUSD = estimatedCostUSD
    }

    /// Display name of `transcriptionMode`, falling back to the raw value.
    public var transcriptionModeLabel: String? {
        guard let transcriptionMode else { return nil }
        return GeminiLiveMode(rawValue: transcriptionMode)?.displayName ?? transcriptionMode
    }
}
