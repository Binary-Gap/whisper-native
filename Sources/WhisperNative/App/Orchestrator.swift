import AppKit
import Foundation
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
    private let textInserter: any TextInserting
    private let indicator: RecordingIndicator
    private let liveTranscriptPill: LiveTranscriptPill
    // Read-only: lets a whisper-engine recording attempt tell a first-run/
    // engine-switch model download apart from an actually-dead server.
    private let modelSectionState: ModelSectionState

    // MARK: - State

    private var isRecording = false {
        didSet { notifyActiveStateIfChanged() }
    }
    private var isTranscribing = false {
        didSet { notifyActiveStateIfChanged() }
    }

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

    // iTerm2 session ID captured at recording start, if recording started in iTerm2.
    private var recordingItermSessionID: String?

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

    // Re-transcribes the in-progress recording for LiveTranscriptPill (Parakeet only).
    private var livePreviewTask: Task<Void, Never>?

    // MARK: - Init

    init(
        store: SettingsStore,
        serverManager: any WhisperServerManaging,
        audioRecorder: any AudioRecording,
        backend: any TranscriptionBackend,
        parakeetBackend: ParakeetBackend,
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
        if !isRecording && isTranscribing {
            // Already transcribing — ignore new toggle (MVP: no queuing).
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
        transcriptionCancelled = true

        if isRecording {
            isRecording = false
            indicator.hide()
            stopLivePreview()
            Task {
                _ = try? await audioRecorder.stopRecording()
            }
        }
        AppLogger.shared.log(.info, "Cancel (2nd press): transcription cancelled by user")
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
        AppLogger.shared.log(.error, "Recording failed: \(error)")
        showAlert(title: "Recording failed", message: error.localizedDescription)
    }

    // MARK: - Private

    private func startRecording() async {
        // Pre-flight health check (Parakeet runs in-process, no server).
        if store.config.transcriptionEngine == .whisper, !(await serverManager.healthCheck()) {
            if modelSectionState.isDownloading {
                let percent = Int((modelSectionState.downloadProgress * 100).rounded())
                showAlert(
                    title: "Model downloading",
                    message: "Model still downloading, \(percent)%."
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

        // Capture frontmost app for post-transcription paste decision.
        recordingFocusedBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        recordingItermSessionID = nil
        suppressAutoSubmitForCurrentRecording = false
        cancelPressCount = 0
        transcriptionCancelled = false
        if recordingFocusedBundleID == ItermBridge.bundleIdentifier {
            recordingItermSessionID = await Task.detached { ItermBridge.currentSessionID() }.value
        }

        // Generate a millisecond-timestamped WAV path in the persistent history
        // dir (millis avoids the same-second filename collision of epoch seconds).
        let timestampMillis = Int(Date().timeIntervalSince1970 * 1000)
        let wavPath = Constants.historyDirectory.appendingPathComponent("recording_\(timestampMillis).wav")

        do {
            audioRecorder.preferredInputDeviceUID = store.config.inputDeviceUID
            audioRecorder.soundFeedbackEnabled = store.config.soundFeedback
            audioRecorder.soundVolume = store.config.soundVolume
            try await audioRecorder.startRecording(to: wavPath)
            isRecording = true
            if store.config.transcriptionEngine == .parakeet {
                startLivePreview(recordingURL: wavPath)
            }
        } catch {
            indicator.hide()
            AppLogger.shared.log(.error, "startRecording failed: \(error)")
            showAlert(title: "Recording failed", message: error.localizedDescription)
        }
    }

    private func stopRecordingAndTranscribe() async {
        isRecording = false
        indicator.hide()
        stopLivePreview()

        let wavURL: URL
        do {
            wavURL = try await audioRecorder.stopRecording()
        } catch {
            AppLogger.shared.log(.error, "stopRecording failed: \(error)")
            showAlert(title: "Recording error", message: error.localizedDescription)
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let result: TranscriptionResult
        do {
            result = try await transcribeWithCalibration(recordingURL: wavURL)
        } catch {
            AppLogger.shared.log(.error, "Transcription failed: \(error)")
            // Persist a failed entry so the recording stays rerunnable from History.
            recordHistoryEntry(audioURL: wavURL, text: "", language: store.config.selectedLanguage, durationSeconds: nil, status: .failed)
            showAlert(title: "Transcription failed", message: error.localizedDescription)
            return
        }

        lastTranscript = result.text
        recordHistoryEntry(audioURL: wavURL, text: result.text, language: result.language, durationSeconds: result.durationSeconds, status: .success)

        // Cancelled (2nd press) while transcribing: keep the transcript in history
        // and as lastTranscript, but skip the auto-paste entirely.
        if transcriptionCancelled {
            AppLogger.shared.log(.info, "Transcription cancelled: skipping auto-paste")
            return
        }

        // Empty transcript (silence / VAD dropped everything): nothing to insert.
        // Skip paste/submit so we don't emit an empty (or bare audio-tag) line.
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppLogger.shared.log(.info, "Empty transcript: skipping auto-paste")
            return
        }

        let frontmostNow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sameApp = frontmostNow == recordingFocusedBundleID && recordingFocusedBundleID != nil

        let outgoingText = store.config.prependAudioTags
            ? Constants.wrapWithAudioTags(result.text)
            : result.text

        if let sessionID = recordingItermSessionID,
           await ItermBridge.sendText(outgoingText, toSession: sessionID, submitWithEnter: store.config.autoSubmitInTerminal && !suppressAutoSubmitForCurrentRecording) {
            AppLogger.shared.log(.info, "Transcript sent to iTerm2 session \(sessionID)")
            playFeedbackSound(named: "Purr")
        } else if sameApp && store.config.autoPasteWhenSameApp {
            do {
                try await textInserter.insertText(outgoingText)
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

    /// Anchors the pill near the focused text input, then every
    /// livePreviewInterval re-transcribes everything recorded so far and
    /// shows it in the pill. Passes run back to back (never overlapping), so a
    /// slow pass just stretches the interval. The pasted text still comes from
    /// the normal full transcription at stop.
    private func startLivePreview(recordingURL: URL) {
        livePreviewTask?.cancel()
        let language = store.config.selectedLanguage
        livePreviewTask = Task { [weak self, parakeetBackend] in
            // Locate the input once, at recording start: the pill stays put even
            // if the caret moves.
            let anchor = await Task.detached { TextInputLocator.locate() }.value
            guard !Task.isCancelled else { return }
            AppLogger.shared.log(.debug, "Live preview anchor: \(anchor.sourceName)")
            self?.liveTranscriptPill.setAnchor(anchor)
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
                } catch {
                    AppLogger.shared.log(.warning, "Live preview failed: \(error)")
                }
            }
        }
    }

    private func stopLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        liveTranscriptPill.hide()
    }

    // MARK: - Voice calibration

    /// Transcribes the real recording, optionally prepending the cached voice
    /// calibration sample for acoustic priming and stripping its text back out
    /// of the result. Falls through to a plain transcribe when calibration is
    /// off, no sample exists, or the recording is already long enough to give
    /// whisper sufficient acoustic context on its own.
    private func transcribeWithCalibration(recordingURL: URL) async throws -> TranscriptionResult {
        let config = store.config
        // Calibration primes whisper's acoustic context; Parakeet doesn't use it.
        if config.transcriptionEngine == .parakeet {
            return try await parakeetBackend.transcribe(audioFile: recordingURL, config: config)
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
        let entry = HistoryEntry(
            audioFilePath: audioURL,
            text: text,
            language: language,
            modelName: store.config.selectedModelName,
            status: status,
            durationSeconds: durationSeconds
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
