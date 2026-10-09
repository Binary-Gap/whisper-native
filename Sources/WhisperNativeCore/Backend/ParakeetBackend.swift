import FluidAudio
import Foundation

/// Load/download status of Parakeet's in-process models, surfaced to the
/// onboarding engine/model step so it can show progress without a separate
/// downloader (unlike whisper's model files, Parakeet's download is opaque to
/// callers; there is no byte-level progress).
public enum ParakeetLoadState: Sendable, Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

/// Parakeet TDT v3 via FluidAudio, run in-process on the Neural Engine. Models
/// (ASR + Silero VAD) download from HuggingFace on first load into FluidAudio's
/// cache (`~/Library/Application Support/FluidAudio/Models`). One shared instance
/// so dictation and History reruns reuse the loaded models.
public actor ParakeetBackend: TranscriptionBackend {
    public static let shared = ParakeetBackend()

    public static let modelVersion = AsrModelVersion.v3

    private var loadTask: Task<(AsrManager, VadManager), Error>?
    private var currentLoadState: ParakeetLoadState = .notLoaded
    private var speechDownloadFraction: Double?
    private var downloadTasks: [ParakeetModelKind: Task<Void, Error>] = [:]

    /// Whether the ASR model is already in FluidAudio's cache, so loading it
    /// skips the ~500 MB download.
    public nonisolated static var modelsDownloaded: Bool {
        ParakeetModelKind.speech.isDownloaded()
    }

    /// Loads (downloading if needed) both models, so the first dictation after
    /// selecting Parakeet doesn't pay for it.
    public func preload() async throws {
        _ = try await managers()
    }

    /// Current load/download status, for UI that wants to show progress
    /// without triggering a load itself.
    public func loadState() -> ParakeetLoadState {
        currentLoadState
    }

    /// Fraction (0...1) of the speech model's file download while a download
    /// or load fetches it; nil before the first file, while compiling, and idle.
    public func speechModelDownloadFraction() -> Double? {
        speechDownloadFraction
    }

    /// True while `download(_:)` or a load is fetching this model.
    public func isDownloading(_ kind: ParakeetModelKind) -> Bool {
        if downloadTasks[kind] != nil { return true }
        guard currentLoadState == .loading, !kind.isDownloaded() else { return false }
        // A load fetches the speech model first, then the VAD.
        return kind == .speech || Self.modelsDownloaded
    }

    /// Downloads one model into FluidAudio's cache without keeping it loaded,
    /// so Settings can fetch it ahead of selecting Parakeet.
    public func download(_ kind: ParakeetModelKind) async throws {
        if let running = downloadTasks[kind] { return try await running.value }
        let task: Task<Void, Error>
        switch kind {
        case .speech:
            let progressHandler = speechProgressHandler()
            task = Task {
                _ = try await AsrModels.download(version: Self.modelVersion, progressHandler: progressHandler)
            }
        case .vad:
            task = Task { _ = try await VadManager() }
        }
        downloadTasks[kind] = task
        defer {
            downloadTasks[kind] = nil
            if kind == .speech { speechDownloadFraction = nil }
        }
        try await task.value
        AppLogger.shared.log(.info, "Downloaded Parakeet model \(kind.displayName)")
    }

    // FluidAudio's repo loads spend 0-0.5 of `fractionCompleted` downloading and
    // the rest compiling; the download half is rescaled to 0...1.
    private nonisolated func speechProgressHandler() -> ProgressHandler {
        { [weak self] progress in
            let fraction: Double? = switch progress.phase {
            case .listing, .downloading: min(1, progress.fractionCompleted * 2)
            case .compiling: nil
            }
            Task { await self?.setSpeechDownloadFraction(fraction) }
        }
    }

    private func setSpeechDownloadFraction(_ fraction: Double?) {
        // A late progress callback must not resurrect the bar after the fetch ends.
        guard downloadTasks[.speech] != nil || currentLoadState == .loading else { return }
        speechDownloadFraction = fraction
    }

    /// Frees the loaded models (called when switching back to whisper).
    public func unload() async {
        guard let loadTask else { return }
        self.loadTask = nil
        if let (asrManager, _) = try? await loadTask.value {
            await asrManager.cleanup()
        }
        currentLoadState = .notLoaded
        AppLogger.shared.log(.info, "Parakeet models unloaded")
    }

    private func managers() async throws -> (AsrManager, VadManager) {
        if let loadTask { return try await loadTask.value }
        currentLoadState = .loading
        // A Settings download of the same files finishes first instead of racing it.
        let pendingSpeechDownload = downloadTasks[.speech]
        let progressHandler = speechProgressHandler()
        let task = Task {
            _ = try? await pendingSpeechDownload?.value
            let startTime = Date()
            let version = Self.modelVersion
            let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: progressHandler)
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
            let result = try await task.value
            currentLoadState = .ready
            speechDownloadFraction = nil
            return result
        } catch {
            loadTask = nil
            speechDownloadFraction = nil
            currentLoadState = .failed(error.localizedDescription)
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
