import Foundation

/// One transcription run recorded for the History view: the audio file plus the
/// resulting text and metadata. Persisted as JSON via `TranscriptionHistoryStore`.
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case failed
    }

    public let id: UUID
    public var timestamp: Date
    /// Absolute file URL into `Constants.historyDirectory`. May be missing on
    /// disk (grey out Play/Reveal in the view rather than crashing).
    public var audioFilePath: URL
    /// Empty string when the run failed or was not yet transcribed.
    public var text: String
    /// Language actually used for the run.
    public var language: Language
    /// `Config.selectedModelName` at run time.
    public var modelName: String
    public var status: Status
    /// Transcription wall-time, when known.
    public var durationSeconds: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        audioFilePath: URL,
        text: String,
        language: Language,
        modelName: String,
        status: Status,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.audioFilePath = audioFilePath
        self.text = text
        self.language = language
        self.modelName = modelName
        self.status = status
        self.durationSeconds = durationSeconds
    }
}
