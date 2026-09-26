import AVFoundation
import SwiftUI
import WhisperNativeCore

// MARK: - Audio Tab

struct AudioTab: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var calibrationRecorder = VoiceCalibrationRecorder()
    @State private var availableInputDevices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Input") {
                Picker("Microphone", selection: inputDeviceBinding) {
                    Text("System Default").tag(Optional<String>.none)
                    ForEach(availableInputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .pickerStyle(.menu)
                .onAppear { refreshInputDevices() }
            }

            Section("Processing") {
                LabeledToggle(
                    "Normalize audio",
                    help: "Level out recording volume before transcription.",
                    isOn: $store.config.normalizeAudio
                )
                Picker("Noise reduction", selection: $store.config.noiseReduction) {
                    Text("Off").tag(0)
                    Text("5 dB").tag(5)
                    Text("10 dB").tag(10)
                    Text("15 dB").tag(15)
                    Text("20 dB").tag(20)
                }
                .pickerStyle(.menu)

                Stepper(
                    value: $store.config.recordingTimeoutSeconds,
                    in: 10...600,
                    step: 10
                ) {
                    LabeledContent("Recording timeout") {
                        Text("\(store.config.recordingTimeoutSeconds)s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                PathField(
                    label: "VAD model",
                    help: "Voice-activity model for silence trimming.",
                    path: vadModelPathBinding,
                    isDirectory: false,
                    checksExistence: true,
                    optional: true,
                    readOnly: true
                )
            } header: {
                Text("Voice activity detection")
            } footer: {
                Text("Optional. Leave empty to disable silence trimming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledToggle(
                    "Voice calibration",
                    help: "Improves transcription accuracy by priming whisper with a sample of your voice before each recording.",
                    isOn: $store.config.voiceCalibrationEnabled
                )
                .disabled(!store.config.voiceCalibrationSampleExists)

                HStack(spacing: 8) {
                    Button(calibrationRecorder.isRecording ? "Stop" : sampleButtonTitle) {
                        Task { await toggleCalibrationRecording() }
                    }
                    .disabled(calibrationRecorder.isTranscribingSample)

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
            } header: {
                Text("Voice calibration")
            } footer: {
                Text("Record a short sample of your own voice (10-20s of normal speech). Re-recording replaces the sample and its cached transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var inputDeviceBinding: Binding<String?> {
        Binding(
            get: { store.config.inputDeviceUID },
            set: { store.config.inputDeviceUID = $0 }
        )
    }

    private func refreshInputDevices() {
        availableInputDevices = AudioRecorder.listInputDevices()
        // Drop a stale selection (device unplugged since last launch) back to system default.
        if let uid = store.config.inputDeviceUID, !availableInputDevices.contains(where: { $0.uid == uid }) {
            store.config.inputDeviceUID = nil
        }
    }

    private var vadModelPathBinding: Binding<URL?> {
        Binding(
            get: { store.config.vadModelPath },
            set: { store.config.vadModelPath = $0 }
        )
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
            await calibrationRecorder.start(preferredInputDeviceUID: store.config.inputDeviceUID, store: store)
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

    func start(preferredInputDeviceUID: String?, store: SettingsStore) async {
        lastErrorMessage = nil
        stopPlayback()
        pendingStore = store
        do {
            audioRecorder.preferredInputDeviceUID = preferredInputDeviceUID
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
