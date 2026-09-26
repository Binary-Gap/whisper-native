import FluidAudio
import Foundation

/// Parakeet TDT v3 via FluidAudio, run in-process on the Neural Engine. Models
/// (ASR + Silero VAD) download from HuggingFace on first load into FluidAudio's
/// cache (`~/Library/Application Support/FluidAudio/Models`). One shared instance
/// so dictation and History reruns reuse the loaded models.
public actor ParakeetBackend: TranscriptionBackend {
    public static let shared = ParakeetBackend()

    public static let modelVersion = AsrModelVersion.v3

    private var loadTask: Task<(AsrManager, VadManager), Error>?

    /// Loads (downloading if needed) both models, so the first dictation after
    /// selecting Parakeet doesn't pay for it.
    public func preload() async throws {
        _ = try await managers()
    }

    /// Frees the loaded models (called when switching back to whisper).
    public func unload() async {
        guard let loadTask else { return }
        self.loadTask = nil
        if let (asrManager, _) = try? await loadTask.value {
            await asrManager.cleanup()
        }
        AppLogger.shared.log(.info, "Parakeet models unloaded")
    }

    private func managers() async throws -> (AsrManager, VadManager) {
        if let loadTask { return try await loadTask.value }
        let task = Task {
            let startTime = Date()
            let version = Self.modelVersion
            let models = try await AsrModels.downloadAndLoad(version: version)
            let asrManager = AsrManager(config: ASRConfig(
                tdtConfig: TdtConfig(blankId: version.blankId),
                encoderHiddenSize: version.encoderHiddenSize
            ))
            try await asrManager.loadModels(models)
            let vadManager = try await VadManager()
            AppLogger.shared.log(.info, "Parakeet models loaded in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
            return (asrManager, vadManager)
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil
            throw AppError.transcriptionFailed("Parakeet model load failed: \(error.localizedDescription)")
        }
    }

    public func transcribe(audioFile: URL, config: Config) async throws -> TranscriptionResult {
        let startTime = Date()
        let (asrManager, vadManager) = try await managers()

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(audioFile)
        } catch {
            throw AppError.transcriptionFailed("Failed to read audio file: \(error.localizedDescription)")
        }

        // Transcribe only the speech. Wider padding than FluidAudio's 0.1s default
        // so the first/last word at a segment edge isn't clipped.
        var segmentation = VadSegmentationConfig.default
        segmentation.speechPadding = 0.3
        let speech = try await vadManager.segmentSpeechAudio(samples, config: segmentation).flatMap { $0 }
        guard !speech.isEmpty else { throw AppError.transcriptionEmpty }

        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            speech,
            decoderState: &decoderState,
            language: Self.tokenFilterLanguage(for: config.selectedLanguage)
        )

        var text = WhisperClient.cleanTranscriptText(
            FillerRemover.removeFillers(from: result.text, language: config.selectedLanguage)
        )
        if config.sentencePerLine {
            text = WhisperClient.splitSentencesOntoLines(text)
        }
        if config.lineWrapEnabled {
            text = LineWrapper.wrap(text, width: min(100, max(20, config.lineWrapWidth)))
        }
        guard !text.isEmpty else { throw AppError.transcriptionEmpty }

        let durationSeconds = Date().timeIntervalSince(startTime)
        AppLogger.shared.log(
            .info,
            "Transcribe done: backend=parakeet language=\(config.selectedLanguage.rawValue) "
                + "audioSeconds=\(String(format: "%.1f", Double(samples.count) / 16_000)) "
                + "speechSeconds=\(String(format: "%.1f", Double(speech.count) / 16_000)) "
                + "tookSeconds=\(String(format: "%.2f", durationSeconds))"
        )
        return TranscriptionResult(
            text: text,
            language: config.selectedLanguage,
            durationSeconds: durationSeconds,
            audioFilePath: audioFile
        )
    }

    /// Live-preview transcript of the audio captured so far. Skips VAD and the
    /// sentence-per-line split (the pill shows the text as one flowing block);
    /// returns an empty string for audio too short to decode.
    public func transcribePreview(samples: [Float], language: Language) async throws -> String {
        guard samples.count >= Self.minimumPreviewSamples else { return "" }
        let (asrManager, _) = try await managers()
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            samples, decoderState: &decoderState, language: Self.tokenFilterLanguage(for: language)
        )
        return WhisperClient.cleanTranscriptText(FillerRemover.removeFillers(from: result.text, language: language))
    }

    /// FluidAudio's decoder hint. Parakeet always auto-detects the language; the
    /// hint only filters decoder tokens to the language's script (Latin, Cyrillic
    /// or Greek), which stops stray Cyrillic like "Agent браузер" in Latin text.
    /// A language FluidAudio knows passes through. An unsupported one gets the
    /// Latin filter when it is Latin-script, and auto gets it when the system
    /// language is (Portuguese stands in for any Latin language); anything else
    /// gets no filter.
    ///
    /// Generic over the hint type because `FluidAudio.Language` can't be spelled
    /// here: this module's `Language` shadows it and FluidAudio's `FluidAudio`
    /// struct shadows the module name. Callers infer FluidAudio's enum from
    /// `transcribe(_:decoderState:language:)`.
    static func tokenFilterLanguage<Hint: RawRepresentable>(
        for selected: Language,
        systemLanguageCode: String? = Locale.current.language.languageCode?.identifier
    ) -> Hint? where Hint.RawValue == String {
        if let supported = Hint(rawValue: selected.rawValue) { return supported }
        let scriptCode = selected == .auto ? systemLanguageCode : selected.rawValue
        guard let scriptCode, Language.isLatinScript(code: scriptCode) else { return nil }
        return Hint(rawValue: Language.portuguese.rawValue)
    }

    // One second at 16kHz: shorter clips give Parakeet too little context to say anything useful.
    private static let minimumPreviewSamples = 16_000

    /// Parakeet has no timestamped-segment path wired; returns no segments.
    public func transcribeWithSegments(audioFile: URL, config: Config) async throws -> (result: TranscriptionResult, segments: [TranscriptionSegment]) {
        (try await transcribe(audioFile: audioFile, config: config), [])
    }

    public func isAvailable() async -> Bool {
        true
    }
}
