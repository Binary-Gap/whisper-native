import AppKit
import Foundation
import MusicPause
import WhisperNativeCore

// Orchestrator owns the recording / transcription state machine.
// All methods are @MainActor because they touch MainActor-isolated types
// (AudioRecorder, RecordingIndicator, TextInserter) and must be called from
// the main thread via the HotkeyManager callbacks.
@MainActor
final class Orchestrator {

    // MARK: - Dependencies

    private let store: SettingsStore
    private let serverManager: any WhisperServerManaging
    private let audioRecorder: any AudioRecording
    private let backend: any TranscriptionBackend
    private let parakeetBackend: ParakeetBackend
    private let geminiBackend: GeminiBackend
    private let textInserter: any TextInserting
    private let indicator: RecordingIndicator
    private let liveTranscriptPill: LiveTranscriptPill
    // Read-only: lets a whisper-engine recording attempt tell a first-run/
    // engine-switch model download apart from an actually-dead server.
    private let modelSectionState: ModelSectionState
    // Pauses Apple Music from recording start to recording end (Config.pauseMusicWhileRecording).
    private let musicPauser = MusicPauser(report: { AppLogger.shared.log(.info, $0) })

    // MARK: - State

    private var isRecording = false {
        didSet { notifyActiveStateIfChanged() }
    }
    private var isTranscribing = false {
        didSet { notifyActiveStateIfChanged() }
    }
    // startRecording is awaiting (iTerm2 session lookup, mic warmup): a second
    // toggle or a voice onset in that window is ignored, so only one recording
    // and one Gemini Live session start.
    private var isStartingRecording = false

    // Fired when the "recording or transcribing" state flips. AppDelegate wires
    // this to enable/disable the cancel hotkey so the key only captures while a
    // recording/transcription is in flight.
    var onActiveStateChanged: (@MainActor (Bool) -> Void)?

    // Tracks the last-notified active state so didSet observers only fire the
    // callback on an actual transition.
    private var lastNotifiedActive = false

    // Bundle ID of the app that was frontmost when recording started; used to
    // decide whether to auto-paste or just copy to clipboard on completion.
    private var recordingFocusedBundleID: String?

    // Lookup of the iTerm2 session focused at recording start, if recording started
    // in iTerm2. Runs alongside the mic start; awaited only when inserting.
    private var recordingItermSessionLookup: Task<String?, Never>?

    // Set when the cancel key is pressed once during a terminal-targeted recording
    // with auto-submit enabled: suppresses the Enter keypress for that one
    // transcription instead of cancelling the recording outright.
    private var suppressAutoSubmitForCurrentRecording = false

    // Number of cancel-key presses within the current recording/transcription
    // lifecycle. 1st press arms skip-auto-submit; 2nd press cancels outright.
    // Reset to 0 at the start of every recording.
    private var cancelPressCount = 0

    // Set when the cancel key is pressed a second time: aborts the pending paste
    // once transcription finishes so the transcript is discarded, not inserted.
    private var transcriptionCancelled = false

    // Most recent successful transcript (for handlePasteLast).
    private var lastTranscript: String?

    // Anchors LiveTranscriptPill and, with Parakeet, re-transcribes the
    // in-progress recording for it.
    private var livePreviewTask: Task<Void, Never>?

    // Gemini Live session of the current dictation, from recording start until
    // its transcript is in (or it's cancelled).
    private var geminiLiveSession: GeminiLiveSession?
    // Identifies the session whose previews may still reach the pill.
    private var geminiLivePreviewToken: UUID?

    // Say a stop word to stop: the recording's stop words, picked at recording
    // start (nil when not listening for one) and reused to strip the word at stop.
    private var stopWordMatcher: StopWordMatcher?
    // Fed the live transcript while recording.
    private var stopWordWatcher: StopWordWatcher?
    // The current recording ended on the spoken stop word, which gets stripped.
    private var stoppedBySpokenWord = false

    // Start on voice: watches the open mic for speech while nothing is in flight.
    private var voiceStartDetector: VoiceStartDetector?
    // What started the current recording; read only while isRecording.
    private var recordingOrigin: RecordingOrigin = .hotkey

    // Screen locked or Mac asleep (set by AppDelegate): nobody is dictating, so
    // the mic closes and stays closed until it clears.
    var voiceStartSuspended = false {
        didSet { refreshVoiceStart() }
    }

    // MARK: - Init

    init(
        store: SettingsStore,
        serverManager: any WhisperServerManaging,
        audioRecorder: any AudioRecording,
        backend: any TranscriptionBackend,
        parakeetBackend: ParakeetBackend,
        geminiBackend: GeminiBackend,
        textInserter: any TextInserting,
        indicator: RecordingIndicator,
        liveTranscriptPill: LiveTranscriptPill,
        modelSectionState: ModelSectionState
    ) {
        self.store = store
        self.serverManager = serverManager
        self.audioRecorder = audioRecorder
        self.backend = backend
        self.parakeetBackend = parakeetBackend
        self.geminiBackend = geminiBackend
        self.textInserter = textInserter
        self.indicator = indicator
        self.liveTranscriptPill = liveTranscriptPill
        self.modelSectionState = modelSectionState
    }

    private func notifyActiveStateIfChanged() {
        let active = isRecording || isTranscribing
        guard active != lastNotifiedActive else { return }
        lastNotifiedActive = active
        onActiveStateChanged?(active)
    }

    // MARK: - Public handlers (called by HotkeyManager)

    /// Toggle recording on/off. The full state machine lives here.
    func handleToggle() async {
        if !isRecording && (isTranscribing || isStartingRecording) {
            // Already transcribing or starting: ignore new toggle (MVP: no queuing).
            return
        }

        if !isRecording {
            await startRecording()
        } else {
            await stopRecordingAndTranscribe()
        }
    }

    /// Two-stage cancel, active only while a recording or transcription is in
    /// flight (otherwise the key passes through to the OS/app). First press arms
    /// skip-auto-submit for this one transcription (the transcript still gets
    /// pasted, just without the trailing Enter). Second press cancels the whole
    /// transcription — the recording stops and the transcript is discarded.
    func handleCancel() {
        guard isRecording || isTranscribing else { return }

        cancelPressCount += 1

        if cancelPressCount == 1 {
            suppressAutoSubmitForCurrentRecording = true
            AppLogger.shared.log(.info, "Cancel (1st press): auto-submit suppressed for this transcription")
            return
        }

        // Second (or later) press: cancel outright.
        cancelOutright()
        AppLogger.shared.log(.info, "Cancel (2nd press): transcription cancelled by user")
    }

    /// Stops the recording (if one runs) and discards the dictation: nothing is
    /// transcribed or pasted, the Gemini Live socket closes, music resumes.
    private func cancelOutright() {
        transcriptionCancelled = true

        if isRecording {
            isRecording = false
            indicator.hide()
            stopLivePreview()
            musicPauser.resume()
            Task {
                _ = try? await audioRecorder.stopRecording()
                refreshVoiceStart()
            }
        }
        cancelGeminiLiveSession()
    }

    /// Re-insert the most recent successful transcript.
    func handlePasteLast() async {
        // In-memory value is nil until the first dictation of this app session;
        // fall back to the newest successful entry persisted in history.
        let text = lastTranscript
            ?? TranscriptionHistoryStore.shared.entries
                .first(where: { $0.status == .success && !$0.text.isEmpty })?
                .text
        guard let text else {
            AppLogger.shared.log(.info, "handlePasteLast: no transcript available to paste")
            return
        }
        do {
            if store.config.prependAudioTags {
                try await textInserter.insertTextWithAudioTags(text)
            } else {
                try await textInserter.insertText(text)
            }
        } catch {
            AppLogger.shared.log(.error, "handlePasteLast insertText failed: \(error)")
        }
    }

    // MARK: - Internal callback (wired by AppDelegate)

    /// Called when AudioRecorder fires onRecordingFailed (e.g. timeout).
    func handleRecordingFailed(_ error: AppError) {
        isRecording = false
        isTranscribing = false
        indicator.hide()
        stopLivePreview()
        musicPauser.resume()
        cancelGeminiLiveSession()
        AppLogger.shared.log(.error, "Recording failed: \(error)")
        showAlert(title: "Recording failed", message: error.localizedDescription)
        refreshVoiceStart()
    }

    // MARK: - Start on voice

    /// Opens the mic and watches for speech when start on voice is on and the
    /// app is idle; closes it otherwise. Called on every change that can flip
    /// that: the setting, the input device, lock/sleep, and the end of each
    /// dictation, which re-arms it.
    func refreshVoiceStart() {
        let shouldListen = store.config.startOnVoice && !voiceStartSuspended && !isRecording && !isTranscribing
        guard shouldListen else {
            disarmVoiceStart()
            return
        }
        guard voiceStartDetector == nil else { return }
        let detector = VoiceStartDetector { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleVoiceStart()
            }
        }
        audioRecorder.stopListening()
        audioRecorder.preferredInputDeviceUID = store.config.inputDeviceUID
        do {
            try audioRecorder.startListening { detector.append($0) }
            voiceStartDetector = detector
            AppLogger.shared.log(.info, "Start on voice: listening")
        } catch {
            detector.stop()
            AppLogger.shared.log(.warning, "Start on voice: could not open the mic: \(error)")
        }
    }

    /// Runs on every change of the setting (status menu, hotkey, Settings) or
    /// the input device: turning the setting off cancels a recording Start on
    /// voice started (a hotkey recording keeps going), then the mic re-arms
    /// with the current input device or closes.
    func startOnVoiceSettingsChanged() {
        if isRecording, recordingOrigin.isCancelled(startOnVoice: store.config.startOnVoice) {
            cancelOutright()
            AppLogger.shared.log(.info, "Start on voice turned off: voice-started recording cancelled")
        }
        restartVoiceStart()
    }

    /// Runs at launch and on every change of Voice processing or the input
    /// device: builds the voice-processing engine ahead of the next hotkey
    /// dictation, or releases it.
    func voiceProcessingSettingsChanged() {
        audioRecorder.preferredInputDeviceUID = store.config.inputDeviceUID
        audioRecorder.voiceProcessingEnabled = store.config.voiceProcessing
        audioRecorder.prepareVoiceProcessing()
    }

    /// Closes the mic and re-arms with the current input device.
    func restartVoiceStart() {
        disarmVoiceStart()
        refreshVoiceStart()
    }

    private func disarmVoiceStart() {
        voiceStartDetector?.stop()
        voiceStartDetector = nil
        audioRecorder.stopListening()
    }

    private func handleVoiceStart() async {
        guard voiceStartDetector != nil, audioRecorder.isListening, !isRecording, !isTranscribing, !isStartingRecording else { return }
        await startRecording(origin: .voice)
    }

    // MARK: - Private

    /// - Parameter origin: `.voice` (start-on-voice detection) opens the
    ///   recording with the audio heard just before it, so the first word survives.
    private func startRecording(origin: RecordingOrigin = .hotkey) async {
        // Watching for speech ends here; the mic stays open for the recording.
        voiceStartDetector?.stop()
        voiceStartDetector = nil
        defer {
            if !isRecording { refreshVoiceStart() }
        }
        isStartingRecording = true
        // Declared after the re-arm defer, so it clears first.
        defer { isStartingRecording = false }

        // Pre-flight health check (whisper only: the other engines use no local server).
        if store.config.transcriptionEngine == .whisper, !(await serverManager.healthCheck()) {
            if modelSectionState.isDownloading {
                let percent = Int((modelSectionState.downloadProgress * 100).rounded())
                showAlert(
                    title: "Model downloading",
                    message: "Model still downloading, \(percent)%."
                )
            } else if !FileManager.default.isReadableFile(atPath: store.config.modelPath.path) {
                showAlert(
                    title: "No Whisper model",
                    message: "Whisper has no model downloaded. Download one on the Whisper page in Settings, or switch to another engine."
                )
            } else {
                showAlert(
                    title: "Server not running",
                    message: "whisper-server is not running. Start it from the menu."
                )
            }
            return
        }

        // Configure indicator.
        indicator.isEnabled = store.config.recordingIndicatorEnabled
        indicator.recordingTimedOut = false
        indicator.show()
        // Paused before the mic opens so the music doesn't bleed into the recording.
        if store.config.pauseMusicWhileRecording {
            musicPauser.pause()
        }

        // Capture frontmost app for post-transcription paste decision.
        recordingFocusedBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        recordingItermSessionLookup = nil
        suppressAutoSubmitForCurrentRecording = false
        cancelPressCount = 0
        transcriptionCancelled = false
        if recordingFocusedBundleID == ItermBridge.bundleIdentifier {
            recordingItermSessionLookup = Task.detached { ItermBridge.currentSessionID() }
        }

        // Generate a millisecond-timestamped WAV path in the persistent history
        // dir (millis avoids the same-second filename collision of epoch seconds).
        let timestampMillis = Int(Date().timeIntervalSince1970 * 1000)
        let wavPath = Constants.historyDirectory.appendingPathComponent("recording_\(timestampMillis).wav")

        let engine = store.config.transcriptionEngine
        do {
            audioRecorder.preferredInputDeviceUID = store.config.inputDeviceUID
            audioRecorder.voiceProcessingEnabled = store.config.voiceProcessing
            audioRecorder.soundFeedbackEnabled = store.config.soundFeedback
            audioRecorder.soundVolume = store.config.soundVolume
            audioRecorder.recordingTimeoutSeconds = store.config.recordingTimeoutSeconds
            // The words file is read once per recording: the stop words (only
            // engines with a live transcript can hear one) and Gemini Live's vocabulary.
            let listensForStopWord = store.config.stopOnOver && engine.hasLiveTranscript
            let recordingWords = listensForStopWord || engine == .geminiLive
                ? WordsFile.load(for: store.config.selectedLanguage)
                : nil
            stopWordMatcher = listensForStopWord ? StopWordMatcher(words: recordingWords?.stopWords ?? []) : nil
            // The socket connects while the mic warms up; audio buffers until setup completes.
            if engine == .geminiLive {
                // Stop words go in the vocabulary too, so Gemini spells them as listed.
                let vocabulary = WordsFile.cappedVocabulary(
                    (recordingWords?.vocabulary ?? []) + (stopWordMatcher?.words ?? []),
                    language: store.config.selectedLanguage
                )
                startGeminiLiveSession(customVocabulary: vocabulary)
            }
            try await audioRecorder.startRecording(to: wavPath, includePreRoll: origin == .voice)
            isRecording = true
            recordingOrigin = origin
            stoppedBySpokenWord = false
            switch engine {
            case .parakeet:
                startStopWordWatcher(confirmation: .consecutiveUpdates)
                startLivePreview(rereading: wavPath)
            case .geminiLive:
                startStopWordWatcher(confirmation: .quietPeriod(Self.stopWordQuietPeriod))
                startLivePreview(rereading: nil)
            case .whisper, .gemini:
                break
            }
            // Start on voice turned off while this recording was starting.
            if origin.isCancelled(startOnVoice: store.config.startOnVoice) {
                cancelOutright()
                AppLogger.shared.log(.info, "Start on voice turned off: voice-started recording cancelled")
            }
        } catch {
            cancelGeminiLiveSession()
            indicator.hide()
            musicPauser.resume()
            AppLogger.shared.log(.error, "startRecording failed: \(error)")
            showAlert(title: "Recording failed", message: error.localizedDescription)
        }
    }

    private func stopRecordingAndTranscribe() async {
        // Runs last, after the paste: the next dictation can start on voice again.
        defer { refreshVoiceStart() }
        isRecording = false
        indicator.hide()
        stopLivePreview()

        let wavURL: URL
        do {
            wavURL = try await audioRecorder.stopRecording()
            audioRecorder.pcmSink = nil
            musicPauser.resume()
        } catch {
            musicPauser.resume()
            cancelGeminiLiveSession()
            AppLogger.shared.log(.error, "stopRecording failed: \(error)")
            showAlert(title: "Recording error", message: error.localizedDescription)
            return
        }

        isTranscribing = true
        defer {
            isTranscribing = false
            // No-op once the session finished; closes it if the engine changed mid-recording.
            cancelGeminiLiveSession()
        }

        let result: TranscriptionResult
        do {
            result = try await transcribeWithCalibration(recordingURL: wavURL)
        } catch is CancellationError {
            // Cancel key during a Gemini Live wait: the socket is closed, no fallback ran.
            AppLogger.shared.log(.info, "Transcription cancelled before the live transcript arrived")
            recordHistoryEntry(audioURL: wavURL, text: "", language: store.config.selectedLanguage, durationSeconds: nil, status: .failed)
            return
        } catch {
            AppLogger.shared.log(.error, "Transcription failed: \(error)")
            // Persist a failed entry so the recording stays rerunnable from History.
            recordHistoryEntry(audioURL: wavURL, text: "", language: store.config.selectedLanguage, durationSeconds: nil, status: .failed)
            showAlert(title: "Transcription failed", message: error.localizedDescription)
            return
        }

        // Ended by saying a stop word: the word is a command, not dictation.
        let transcriptText = stoppedBySpokenWord
            ? (stopWordMatcher?.removingStopWord(from: result.text) ?? result.text)
            : result.text
        lastTranscript = transcriptText
        recordHistoryEntry(audioURL: wavURL, text: transcriptText, language: result.language, durationSeconds: result.durationSeconds, status: .success)

        // Cancelled (2nd press) while transcribing: keep the transcript in history
        // and as lastTranscript, but skip the auto-paste entirely.
        if transcriptionCancelled {
            AppLogger.shared.log(.info, "Transcription cancelled: skipping auto-paste")
            return
        }

        // Empty transcript (silence / VAD dropped everything): nothing to insert.
        // Skip paste/submit so we don't emit an empty (or bare audio-tag) line.
        if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppLogger.shared.log(.info, "Empty transcript: skipping auto-paste")
            return
        }

        let frontmostNow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sameApp = frontmostNow == recordingFocusedBundleID && recordingFocusedBundleID != nil

        let outgoingText = store.config.prependAudioTags
            ? Constants.wrapWithAudioTags(transcriptText)
            : transcriptText

        let itermSessionID = await recordingItermSessionLookup?.value
        let plan = InsertionPlan.make(
            config: store.config,
            itermSessionID: itermSessionID,
            sameApp: sameApp,
            autoSubmitSuppressed: suppressAutoSubmitForCurrentRecording
        )
        if let sessionID = plan.itermSessionID,
           await ItermBridge.sendText(outgoingText, toSession: sessionID, submitWithEnter: plan.submitInTerminal) {
            AppLogger.shared.log(.info, "Transcript sent to iTerm2 session \(sessionID)")
            playFeedbackSound(named: "Purr")
        } else if plan.pasteIntoFocusedApp {
            do {
                try await textInserter.insertText(outgoingText)
                if plan.submitAfterPaste {
                    try await textInserter.pressReturn()
                }
                playFeedbackSound(named: "Purr")
            } catch {
                AppLogger.shared.log(.error, "Text insertion failed: \(error)")
                // Fall back to clipboard.
                textInserter.copyToClipboard(outgoingText)
                if case AppError.accessibilityDenied = error {
                    sendUserNotification(
                        body: "Accessibility permission missing — transcript copied. "
                            + "Grant it in System Settings > Privacy & Security > Accessibility."
                    )
                } else {
                    sendUserNotification(body: "Insertion failed — transcript copied. Use Shift+Cmd+V to paste.")
                }
            }
        } else {
            textInserter.copyToClipboard(outgoingText)
            sendUserNotification(body: "Transcript ready — use Shift+Cmd+V to paste.")
        }
    }

    // MARK: - Live preview

    private static let livePreviewInterval: Duration = .milliseconds(700)

    /// Anchors the pill near the focused text input. With a `recordingURL`
    /// (Parakeet) it then re-transcribes everything recorded so far every
    /// livePreviewInterval and shows it in the pill. Passes run back to back
    /// (never overlapping), so a slow pass just stretches the interval. Gemini
    /// Live passes nil: its socket events feed the pill instead. The pasted text
    /// still comes from the full transcription at stop.
    private func startLivePreview(rereading recordingURL: URL?) {
        livePreviewTask?.cancel()
        let language = store.config.selectedLanguage
        livePreviewTask = Task { [weak self, parakeetBackend] in
            // Locate the input once, at recording start: the pill stays put even
            // if the caret moves.
            let anchor = await Task.detached { TextInputLocator.locate() }.value
            guard !Task.isCancelled else { return }
            AppLogger.shared.log(.debug, "Live preview anchor: \(anchor.sourceName)")
            self?.liveTranscriptPill.setAnchor(anchor)
            guard let recordingURL else { return }
            var lastSampleCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.livePreviewInterval)
                let samples = await Task.detached { WavWriter.readGrowingSamples(from: recordingURL) }.value
                guard !Task.isCancelled, samples.count > lastSampleCount else { continue }
                lastSampleCount = samples.count
                do {
                    let text = try await parakeetBackend.transcribePreview(samples: samples, language: language)
                    guard !Task.isCancelled else { return }
                    self?.liveTranscriptPill.update(text: text)
                    self?.stopWordWatcher?.update(text: text)
                } catch {
                    AppLogger.shared.log(.warning, "Live preview failed: \(error)")
                }
            }
        }
    }

    /// How long Gemini Live must stay quiet after a stop word before the recording ends.
    private static let stopWordQuietPeriod: Duration = .seconds(1)

    private func startStopWordWatcher(confirmation: StopWordWatcher.Confirmation) {
        guard let stopWordMatcher, !stopWordMatcher.isEmpty else { return }
        stopWordWatcher = StopWordWatcher(matcher: stopWordMatcher, confirmation: confirmation) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleSpokenStopWord()
            }
        }
    }

    private func handleSpokenStopWord() async {
        guard isRecording else { return }
        AppLogger.shared.log(.info, "Stop word heard: ending the recording")
        stoppedBySpokenWord = true
        await stopRecordingAndTranscribe()
    }

    private func stopLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        stopWordWatcher?.cancel()
        stopWordWatcher = nil
        geminiLivePreviewToken = nil
        liveTranscriptPill.hide()
    }

    // MARK: - Gemini Live

    /// Opens the dictation's Gemini Live socket and routes recorder audio into
    /// it (the WAV still gets every buffer). Interim transcripts reach the pill
    /// only while this session's recording runs.
    private func startGeminiLiveSession(customVocabulary: [String]) {
        cancelGeminiLiveSession()
        let previewToken = UUID()
        geminiLivePreviewToken = previewToken
        let session = GeminiLiveBackend.startSession(config: store.config, customVocabulary: customVocabulary) { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRecording, self.geminiLivePreviewToken == previewToken else { return }
                    self.liveTranscriptPill.update(text: text)
                    self.stopWordWatcher?.update(text: text)
                }
            }
        }
        geminiLiveSession = session
        if let session {
            audioRecorder.pcmSink = { @Sendable data in session.appendPCM(data) }
        }
    }

    /// Closes the live socket without activityEnd; no fallback call follows.
    private func cancelGeminiLiveSession() {
        audioRecorder.pcmSink = nil
        geminiLivePreviewToken = nil
        geminiLiveSession?.cancel()
        geminiLiveSession = nil
    }

    // MARK: - Voice calibration

    /// Transcribes the real recording, optionally prepending the cached voice
    /// calibration sample for acoustic priming and stripping its text back out
    /// of the result. Falls through to a plain transcribe when calibration is
    /// off, no sample exists, or the recording is already long enough to give
    /// whisper sufficient acoustic context on its own.
    private func transcribeWithCalibration(recordingURL: URL) async throws -> TranscriptionResult {
        let config = store.config
        // Calibration primes whisper's acoustic context; the other engines don't use it.
        switch config.transcriptionEngine {
        case .parakeet:
            return try await parakeetBackend.transcribe(audioFile: recordingURL, config: config)
        case .gemini:
            return try await geminiBackend.transcribe(audioFile: recordingURL, config: config)
        case .geminiLive:
            return try await GeminiLiveBackend.transcribe(
                session: geminiLiveSession,
                audioFile: recordingURL,
                config: config
            ) { [geminiBackend] audioFile, config in
                try await geminiBackend.transcribe(audioFile: audioFile, config: config)
            }
        case .whisper:
            break
        }
        guard config.voiceCalibrationEnabled, config.voiceCalibrationSampleExists else {
            return try await backend.transcribe(audioFile: recordingURL, config: config)
        }

        let recordingDuration = (try? WavConcatenator.duration(ofWavAt: recordingURL)) ?? 0
        guard recordingDuration < Constants.voiceCalibrationSkipDuration else {
            AppLogger.shared.log(.info, "Voice calibration skipped: recording duration \(recordingDuration)s >= threshold")
            return try await backend.transcribe(audioFile: recordingURL, config: config)
        }

        let combinedURL: URL
        do {
            let combinedData = try WavConcatenator.concatenate(
                prefix: Constants.voiceCalibrationSamplePath,
                main: recordingURL
            )
            combinedURL = Constants.tempDirectory.appendingPathComponent("calibrated_\(Int(Date().timeIntervalSince1970)).wav")
            try FileManager.default.createDirectory(at: combinedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try combinedData.write(to: combinedURL)
        } catch {
            AppLogger.shared.log(.warning, "Voice calibration concatenation failed, falling back to plain transcribe: \(error)")
            return try await backend.transcribe(audioFile: recordingURL, config: config)
        }
        defer { try? FileManager.default.removeItem(at: combinedURL) }

        AppLogger.shared.log(.info, "Voice calibration: sending combined audio (sample + recording)")
        let combinedResult = try await backend.transcribe(audioFile: combinedURL, config: config)

        // The calibration sample ends with a fixed anchor phrase; strip everything
        // up to and including it to leave only the real dictation.
        let dictationText = TranscriptStripper.stripCalibrationPrefix(
            from: combinedResult.text,
            anchorPhrase: Constants.voiceCalibrationAnchorPhrase
        )

        return TranscriptionResult(
            text: dictationText,
            language: combinedResult.language,
            durationSeconds: combinedResult.durationSeconds,
            audioFilePath: recordingURL
        )
    }

    // MARK: - Helpers

    private func recordHistoryEntry(
        audioURL: URL,
        text: String,
        language: Language,
        durationSeconds: Double?,
        status: HistoryEntry.Status
    ) {
        let config = store.config
        let audioDurationSeconds = try? WavConcatenator.duration(ofWavAt: audioURL)
        // A failed batch request isn't billed; a failed Live dictation already streamed its audio.
        let isBilled = status == .success || config.transcriptionEngine == .geminiLive
        let entry = HistoryEntry(
            audioFilePath: audioURL,
            text: text,
            language: language,
            modelName: config.selectedModelName,
            status: status,
            durationSeconds: durationSeconds,
            audioDurationSeconds: audioDurationSeconds,
            transcriptionMode: config.transcriptionEngine == .geminiLive ? config.geminiLiveMode.rawValue : nil,
            estimatedCostUSD: isBilled
                ? GeminiPricing.estimatedDollars(
                    modelName: config.selectedModelName, audioSeconds: audioDurationSeconds, text: text
                )
                : nil
        )
        TranscriptionHistoryStore.shared.add(entry)
    }

    private func playFeedbackSound(named name: String) {
        guard store.config.soundFeedback else { return }
        let sound = NSSound(named: name)
        sound?.volume = store.config.soundVolume
        sound?.play()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func sendUserNotification(body: String) {
        // UNUserNotificationCenter is available but requires permission.
        // For simplicity in v1, show a brief NSAlert so the user sees the message
        // without needing notification permission setup.
        let alert = NSAlert()
        alert.messageText = "Whisper Native"
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }
}
