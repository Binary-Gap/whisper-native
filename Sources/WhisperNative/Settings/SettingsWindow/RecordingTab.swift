import SwiftUI
import WhisperNativeCore

// MARK: - Recording Tab

struct RecordingTab: View {
    @ObservedObject var store: SettingsStore
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
                LabeledToggle(
                    "Voice processing",
                    help: "Run the mic through macOS voice processing, the same one FaceTime uses: it suppresses background noise and evens out your volume (automatic gain), for every engine. Helps in noisy rooms or when you speak far from the mic.\n\nTrade-offs: recordings take up to a second longer to start, and the processing can soften quiet words. While a recording runs, macOS slightly lowers other apps' audio (kept at the minimum it allows) and other apps using the same mic hear it much quieter. If it can't start on your mic, the recording uses the unprocessed mic.\n\nCan't be on together with auto-start when you speak: while voice processing runs, macOS gives every other listener of the mic a much quieter signal, so the listening would never hear you. Turning one on turns the other off. Re-record the Whisper voice calibration sample after changing this, so it matches your dictations. A new value applies from the next recording.",
                    isOn: $store.config.voiceProcessing
                )
                ExclusiveTurnOffNote(store: store, setting: .voiceProcessing)
            }

            Section {
                LabeledToggle(
                    "Auto-start when you speak",
                    help: "Keep the mic listening and start recording as soon as you start talking (background noise is ignored). The dictation hotkey still ends the recording. The mic closes while the screen is locked. Turning it off during a recording your voice started cancels that recording (nothing is transcribed or pasted). Also toggled from the menu-bar menu or its shortcut (Settings > Hotkeys).\n\nCan't be on together with voice processing (above): turning one on turns the other off.\n\nUses the voice-detection model listed under Settings > Parakeet (downloads automatically the first time).",
                    isOn: $store.config.startOnVoice
                )
                ExclusiveTurnOffNote(store: store, setting: .startOnVoice)
                LabeledToggle(
                    "Say a stop word to stop",
                    help: "End the recording by saying a stop word as your very last word, then pausing (by default \"over\", or \"câmbio\" in Portuguese). Only the last word counts, so \"talk it over tomorrow\" keeps recording. The word is left out of the text, and the auto-submit settings decide whether Enter follows. Works only with Parakeet and Gemini Live, the engines that transcribe while you talk.\n\nEdit the words in the `stop words` section of `words.yml` (Edit… button): `all` works in every language, a language's list only while dictating in it, and Auto detect uses every list.",
                    unavailableReason: store.config.transcriptionEngine.stopWordUnavailableReason,
                    isOn: $store.config.stopOnOver
                )
                if store.config.stopOnOver && store.config.transcriptionEngine.hasLiveTranscript {
                    StopWordsRow(store: store)
                }
                Stepper(
                    value: $store.config.recordingTimeoutSeconds,
                    in: Constants.recordingTimeoutRange,
                    step: 10
                ) {
                    LabeledContent {
                        Text(RecordingTimeoutFormat.label(seconds: store.config.recordingTimeoutSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        InfoLabel(
                            "Recording timeout",
                            info: "A recording stops on its own after this long. Gemini after recording (batch) accepts up to ~7 min of audio per dictation.\n\nA new value applies from the next recording."
                        )
                    }
                    .font(DesignSystem.Typography.rowTitle)
                }
                if let warning = RecordingTimeoutFormat.geminiBatchWarning(
                    seconds: store.config.recordingTimeoutSeconds,
                    engine: store.config.transcriptionEngine
                ) {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Start and stop")
            }

            Section {
                LabeledToggle(
                    "Sound feedback",
                    help: "Play a cue when recording starts and stops.",
                    isOn: $store.config.soundFeedback
                )
                LabeledToggle(
                    "Recording indicator",
                    help: "Show a floating mic indicator while recording.",
                    isOn: $store.config.recordingIndicatorEnabled
                )
                LabeledToggle(
                    "Pause music while dictating",
                    help: "Pause Apple Music when recording starts and resume it when recording stops. Asks for permission to control Music the first time.",
                    isOn: $store.config.pauseMusicWhileRecording
                )
            } header: {
                Text("Feedback")
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
}

// MARK: - Stop words

/// The stop words in effect (from the words file's `stop words` section, or
/// the defaults) on one line, with an Edit button opening the file. Updates
/// live while visible (`WordsFileModel`).
private struct StopWordsRow: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var wordsFile = WordsFileModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stop words")
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                Button("Edit…") { wordsFile.openInEditor(languages: store.config.activeLanguages) }
            }
            if case .malformed(let reason) = wordsFile.fileState {
                Text("\(wordsFile.fileName) has an error, so the default stop words apply: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if case .loaded(let contents) = wordsFile.fileState {
                ForEach(contents.warnings(for: .stopWords), id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            if let errorMessage = wordsFile.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { await wordsFile.watch() }
    }

    private var summary: String {
        let words = wordsFile.fileState.stopWords.inlineDescription
        return words.isEmpty ? "None, the stop words section is empty" : words
    }
}

/// Status line under voice processing or Start on voice after turning the
/// other one on switched it off.
private struct ExclusiveTurnOffNote: View {
    @ObservedObject var store: SettingsStore
    let setting: ExclusiveMicSetting

    var body: some View {
        if store.lastExclusiveTurnOff == setting {
            Text(VoiceProcessingPolicy.turnedOffNote(setting))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
