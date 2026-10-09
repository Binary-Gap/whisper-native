import Foundation

/// Streaming engine: turns a finished `GeminiLiveSession` into a
/// transcript with the same post-processing as the batch Gemini engine. When
/// the live session failed (connect error, socket drop, timeout) or never
/// started, it falls back to one batch call on the recorded WAV. A cancelled
/// session rethrows `CancellationError` with no fallback call.
public enum GeminiLiveBackend {
    /// How long stop waits for the final transcript before falling back.
    public static let finalTranscriptTimeout: TimeInterval = 5

    /// Starts a session for a new recording, or nil when no API key resolves
    /// (stop then goes straight to the batch call, which reports the missing key).
    /// The words file's vocabulary is read here, once per recording, for the selected
    /// language unless `customVocabulary` is given.
    public static func startSession(
        config: Config,
        apiKey: String? = GeminiAPIKeyStore.resolvedKey,
        customVocabulary: [String]? = nil,
        onPreview: @escaping @Sendable (String) -> Void
    ) -> GeminiLiveSession? {
        guard let apiKey else {
            AppLogger.shared.log(.warning, "Gemini Live: no API key, recording without a live session")
            return nil
        }
        let session = GeminiLiveSession(
            apiKey: apiKey,
            languageCodes: GeminiLiveProtocol.languageCodes(for: config.selectedLanguage),
            mode: config.geminiLiveMode,
            customVocabulary: customVocabulary ?? WordsFile.vocabulary(for: config.selectedLanguage),
            onPreview: { text in
                onPreview(WhisperClient.cleanTranscriptText(FillerRemover.removeFillers(from: text, language: config.selectedLanguage)))
            }
        )
        session.start()
        return session
    }

    public static func transcribe(
        session: GeminiLiveSession?,
        audioFile: URL,
        config: Config,
        fallback: @Sendable (URL, Config) async throws -> TranscriptionResult
    ) async throws -> TranscriptionResult {
        let startTime = Date()
        let fallbackReason: String
        if let session {
            do {
                let rawText = try await session.finish(timeout: finalTranscriptTimeout)
                log(session.metrics, fallback: nil)
                let text = GeminiBackend.postProcess(rawText, config: config)
                guard !text.isEmpty else { throw AppError.transcriptionEmpty }
                return TranscriptionResult(
                    text: text,
                    language: config.selectedLanguage,
                    durationSeconds: Date().timeIntervalSince(startTime),
                    audioFilePath: audioFile
                )
            } catch is CancellationError {
                AppLogger.shared.log(.info, "Gemini Live: session cancelled, no fallback")
                throw CancellationError()
            } catch let error as AppError {
                if case .transcriptionEmpty = error { throw error }
                fallbackReason = error.localizedDescription
                log(session.metrics, fallback: fallbackReason)
            } catch {
                fallbackReason = error.localizedDescription
                log(session.metrics, fallback: fallbackReason)
            }
        } else {
            fallbackReason = "no live session"
            AppLogger.shared.log(.info, "Gemini Live dictation: fallback=yes reason=\(fallbackReason)")
        }

        let audioSeconds = (try? WavConcatenator.duration(ofWavAt: audioFile)) ?? 0
        AppLogger.shared.log(
            .warning,
            "Gemini Live: falling back to one batch Gemini call (audioSeconds=\(String(format: "%.1f", audioSeconds)))"
        )
        return try await fallback(audioFile, config)
    }

    /// One line per dictation: timings, audio length and whether it fell back.
    /// Never the key or the transcript.
    private static func log(_ metrics: GeminiLiveSession.Metrics, fallback reason: String?) {
        func format(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        var line = "Gemini Live dictation: openMs=\(format(metrics.openMilliseconds)) "
            + "setupMs=\(format(metrics.setupMilliseconds)) "
            + "stopToFinalMs=\(format(metrics.stopToFinalMilliseconds)) "
            + "audioSeconds=\(String(format: "%.1f", metrics.audioSeconds)) "
            + "interims=\(metrics.interimCount) finals=\(metrics.finalSegmentCount) "
            + "fallback=\(reason == nil ? "no" : "yes")"
        if let reason { line += " reason=\(reason)" }
        AppLogger.shared.log(reason == nil ? .info : .warning, line)
    }
}
