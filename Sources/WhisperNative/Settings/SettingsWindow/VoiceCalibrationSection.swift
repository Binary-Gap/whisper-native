import AVFoundation
import SwiftUI
import WhisperNativeCore

// MARK: - Voice calibration section

/// Settings > Whisper > Voice calibration: the Record / Play sample controls,
/// the sentence to read and the enable toggle (disabled with a reason until a
/// sample exists). The sample is transcribed
/// by the whisper server, so recording is disabled unless whisper is the
/// active engine (the daemon is booted out otherwise).
struct VoiceCalibrationSection: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var calibrationRecorder = VoiceCalibrationRecorder()

    private var whisperActive: Bool { store.config.transcriptionEngine == .whisper }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button(calibrationRecorder.isRecording ? "Stop" : sampleButtonTitle) {
                    Task { await toggleCalibrationRecording() }
                }
                .disabled(calibrationRecorder.isTranscribingSample || (!whisperActive && !calibrationRecorder.isRecording))

                if store.config.voiceCalibrationSampleExists && !calibrationRecorder.isRecording {
                    Button(calibrationRecorder.isPlaying ? "Pause" : "Play") {
                        if calibrationRecorder.isPlaying {
                            calibrationRecorder.pause()
                        } else {
                            calibrationRecorder.play()
                        }
                    }
                    .disabled(calibrationRecorder.isTranscribingSample)

                    Button("Stop") {
                        calibrationRecorder.stopPlayback()
                    }
                    .disabled(!calibrationRecorder.isPlaying && !calibrationRecorder.isPaused)
                }

                if calibrationRecorder.isTranscribingSample {
                    ProgressView().controlSize(.small)
                    Text("Transcribing sample…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if calibrationRecorder.isRecording {
                    Text("Recording… click Stop when done (auto-stops after \(Int(Constants.voiceCalibrationMaxDuration))s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = calibrationRecorder.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !whisperActive {
                    Text("Recording a sample needs Whisper as the active engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested sentence to read aloud (~10-20s):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsTextBox(contentPadding: 16) {
                    Text(sampleSentence)
                        .font(.body)
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            LabeledToggle(
                "Voice calibration",
                help: "Improves transcription accuracy by priming whisper with a sample of your voice before each recording.",
                unavailableReason: store.config.voiceCalibrationSampleExists ? nil : "Record a sample first.",
                isOn: $store.config.voiceCalibrationEnabled
            )
        } header: {
            InfoLabel("Voice calibration", info: "Record a short sample of your own voice (10-20s of normal speech). Re-recording replaces the sample and its cached transcript.")
        }
    }

    private var sampleButtonTitle: String {
        store.config.voiceCalibrationSampleExists ? "Re-record Sample" : "Record Sample"
    }

    // Ends with Constants.voiceCalibrationAnchorPhrase — the user must read this
    // final phrase so it lands in the transcript and marks where calibration
    // ends and real dictation begins (TranscriptStripper cuts on it).
    private let sampleSentence = """
    I opened the website in my browser and downloaded the file to the \
    Documents folder.
    Then I updated the app, restarted the laptop, and \
    backed everything up to the cloud.
    End of calibration sample.
    """

    private func toggleCalibrationRecording() async {
        if calibrationRecorder.isRecording {
            calibrationRecorder.cancelMaxDurationWatchdog()
            await calibrationRecorder.stopAndTranscribe(store: store)
        } else {
            await calibrationRecorder.start(
                preferredInputDeviceUID: store.config.inputDeviceUID,
                voiceProcessing: store.config.voiceProcessing,
                store: store
            )
        }
    }
}

// MARK: - Voice calibration recorder

/// Drives the "Record Sample" flow in Settings: a manual start/stop recording
/// into the persistent calibration sample path, followed by a one-shot
/// transcription to cache the sample's text. Owns a throwaway AudioRecorder —
/// AudioRecorder has no shared/singleton state (plain `public init()`), so a
/// fresh instance here is safe and avoids reaching into AppDelegate's recorder
/// (which is busy serving real dictation hotkeys).
@MainActor
private final class VoiceCalibrationRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var isTranscribingSample = false
    @Published var lastErrorMessage: String?
    @Published var isPlaying = false
    @Published var isPaused = false

    private let audioRecorder = AudioRecorder()
    private let whisperClient = WhisperClient()
    private var maxDurationTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var pendingStore: SettingsStore?

    /// `voiceProcessing` matches the dictations the sample is prepended to.
    func start(preferredInputDeviceUID: String?, voiceProcessing: Bool, store: SettingsStore) async {
        lastErrorMessage = nil
        stopPlayback()
        pendingStore = store
        do {
            audioRecorder.preferredInputDeviceUID = preferredInputDeviceUID
            audioRecorder.voiceProcessingEnabled = voiceProcessing
            try await audioRecorder.startRecording(to: Constants.voiceCalibrationSamplePath)
            isRecording = true
            scheduleMaxDurationStop()
        } catch {
            lastErrorMessage = "Recording failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "Voice calibration sample recording failed: \(error)")
        }
    }

    private func scheduleMaxDurationStop() {
        maxDurationTask?.cancel()
        let maxDuration = Constants.voiceCalibrationMaxDuration
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRecording, let store = self.pendingStore else { return }
            // Clear the reference before stopping so stopAndTranscribe doesn't
            // cancel the very task it's running on (which would abort the
            // transcribe request below mid-flight).
            self.maxDurationTask = nil
            await self.stopAndTranscribe(store: store)
        }
    }

    /// Cancels a pending auto-stop watchdog. Call before a manual stop so the
    /// watchdog doesn't fire later against a recording that already ended.
    func cancelMaxDurationWatchdog() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
    }

    func stopAndTranscribe(store: SettingsStore) async {
        isRecording = false
        let sampleURL: URL
        do {
            sampleURL = try await audioRecorder.stopRecording()
        } catch {
            lastErrorMessage = "Recording failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "Voice calibration sample stopRecording failed: \(error)")
            return
        }

        // Pad the tail with silence: whisper's VAD sometimes clips the last
        // word right at the recording boundary.
        do {
            try WavConcatenator.appendSilence(toWavAt: sampleURL, seconds: Constants.voiceCalibrationTrailingSilence)
        } catch {
            AppLogger.shared.log(.warning, "Voice calibration trailing silence append failed: \(error)")
        }

        isTranscribingSample = true
        defer { isTranscribingSample = false }

        do {
            let result = try await whisperClient.transcribe(audioFile: sampleURL, config: store.config)
            // Re-record always re-caches the sample transcript (for reference/UI).
            store.config.voiceCalibrationSampleText = result.text

            // The anchor phrase is what stripping keys on; if it didn't land in the
            // transcript, every future dictation would leak the calibration text.
            // Verify it now and warn instead of silently enabling a broken sample.
            let anchorFound = TranscriptStripper.stripCalibrationPrefix(
                from: result.text,
                anchorPhrase: Constants.voiceCalibrationAnchorPhrase
            ) != result.text
            if anchorFound {
                store.config.voiceCalibrationEnabled = true
                lastErrorMessage = nil
            } else {
                store.config.voiceCalibrationEnabled = false
                lastErrorMessage = "Couldn't detect the closing phrase \"\(Constants.voiceCalibrationAnchorPhrase)\". Re-record and read the whole prompt, including the last line."
                AppLogger.shared.log(.warning, "Voice calibration sample missing anchor phrase; transcript: \(result.text)")
            }
        } catch {
            lastErrorMessage = "Sample transcription failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "Voice calibration sample transcription failed: \(error)")
        }
    }

    // MARK: Playback

    func play() {
        guard !isRecording else { return }
        if let player = audioPlayer, isPaused {
            player.play()
            isPlaying = true
            isPaused = false
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: Constants.voiceCalibrationSamplePath)
            player.delegate = self
            audioPlayer = player
            player.play()
            isPlaying = true
            isPaused = false
        } catch {
            lastErrorMessage = "Playback failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "Voice calibration sample playback failed: \(error)")
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        isPaused = true
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        isPaused = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.audioPlayer = nil
            self?.isPlaying = false
            self?.isPaused = false
        }
    }
}
