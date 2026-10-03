import SwiftUI
import WhisperNativeCore

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    // Shared with AppDelegate (not locally owned): a first-run/engine-switch
    // model download is kicked off outside Settings, and this tab just observes
    // its progress rather than running a second, independent downloader.
    @ObservedObject var modelState: ModelSectionState

    var body: some View {
        Form {
            Section {
                Picker("Transcription engine", selection: $store.config.transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                if store.config.transcriptionEngine == .gemini || store.config.transcriptionEngine == .geminiLive {
                    GeminiAPIKeyField()
                }
                if store.config.transcriptionEngine == .geminiLive {
                    Picker("Transcription mode", selection: $store.config.geminiLiveMode) {
                        ForEach(GeminiLiveMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Verbatim keeps every word as spoken. Smart removes disfluencies, applies spoken corrections and formats lists and numbers.")
                }
            } header: {
                Text("Engine")
            } footer: {
                switch store.config.transcriptionEngine {
                case .parakeet:
                    Text("Parakeet auto-detects among 25 European languages (the language setting only narrows its alphabet), removes filler sounds (uh, um), and skips the prompt and voice calibration. The first use downloads its model (~500 MB).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .gemini:
                    Text("Experimental. Sends audio to Google's Gemini API. Needs an API key and internet; ~2 s per dictation; auto-detects 85+ languages; skips the prompt and voice calibration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .geminiLive:
                    Text("Experimental. Streams audio to Google's Gemini Live API while you talk and shows a live transcript. Needs an API key and internet; a fixed language is sent as a hint; skips the prompt and voice calibration. If the stream fails, the recording goes through one regular Gemini call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .whisper:
                    EmptyView()
                }
            }

            Section("Language") {
                LanguageControls(store: store)
            }

            Section("Whisper model") {
                ModelListControls(store: store, modelState: modelState)

                PathField(
                    label: "Models directory",
                    help: "Folder scanned for .bin model files.",
                    path: modelsDirectoryBinding,
                    isDirectory: true,
                    checksExistence: true,
                    readOnly: true
                )
                .onChange(of: store.config.modelsDirectory) { _, newDir in
                    modelState.refreshAndReconcile(directory: newDir, store: store)
                }
            }
            .onAppear { modelState.refreshAndReconcile(directory: store.config.modelsDirectory, store: store) }

            Section("Behavior") {
                LabeledToggle(
                    "Sound feedback",
                    help: "Play a cue when recording starts and stops.",
                    isOn: $store.config.soundFeedback
                )
                LabeledToggle(
                    "Pause music while dictating",
                    help: "Pause Apple Music when recording starts and resume it when recording stops. Asks for permission to control Music the first time.",
                    isOn: $store.config.pauseMusicWhileRecording
                )
                LabeledToggle(
                    "Recording indicator",
                    help: "Show a floating mic indicator while recording.",
                    isOn: $store.config.recordingIndicatorEnabled
                )
                LabeledToggle(
                    "Launch at login",
                    help: "Start Whisper Native automatically when you log in.",
                    isOn: $store.config.launchAtLogin
                )
                LabeledToggle(
                    "Show icon in Dock",
                    help: "Keep a Dock icon and appear in Cmd-Tab. When off, the app stays menu-bar only (the Dock icon still appears while this Settings window is open).",
                    isOn: showDockIconBinding
                )
            }
        }
        .formStyle(.grouped)
    }

    // Only persists the preference; the activation policy is applied when the
    // Settings window closes (it's forced to .regular while this window is open,
    // so flipping the policy live would yank the Dock icon out from under it).
    private var showDockIconBinding: Binding<Bool> {
        Binding(
            get: { store.config.showDockIcon },
            set: { store.config.showDockIcon = $0 }
        )
    }

    private var modelsDirectoryBinding: Binding<URL> {
        Binding(
            get: { store.config.modelsDirectory },
            set: { store.config.modelsDirectory = $0 }
        )
    }

}
