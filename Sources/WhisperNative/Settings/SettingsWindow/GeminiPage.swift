import SwiftUI
import WhisperNativeCore

// MARK: - Gemini page

/// Settings > Engines > Gemini: one page for Gemini (batch) and Gemini Live,
/// which share the API key and vocabulary. A single "Use Gemini" button with
/// the delivery choice (Live / After recording) under it and, while Live is
/// chosen, the text style right below; then the API key and the vocabulary.
/// Explanations sit behind "?" buttons. Editable whichever engine is active.
/// "Use Gemini" stays disabled until a key exists; a key removed while Gemini
/// is active leaves Gemini selected with an orange warning on the activation
/// row and the key field.
struct GeminiPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keyModel = GeminiKeyModel.shared

    private static let geminiEngines: Set<TranscriptionEngine> = [.gemini, .geminiLive]

    var body: some View {
        Form {
            Section {
                EngineActivationRow(
                    store: store,
                    title: "Gemini",
                    info: "Cloud engine: sends your audio to Google's Gemini 3.5 Transcribe, so it needs an API key and internet. 85+ languages.",
                    shortName: "Gemini",
                    engines: Self.geminiEngines,
                    engineToUse: EngineChoice.gemini.engine(geminiStreaming: store.config.geminiStreaming),
                    unavailableReason: keyModel.status.hasKey ? nil : "Add an API key below to use Gemini.",
                    activeWarning: keyModel.status.hasKey ? nil : "No API key: dictation fails until you add one below."
                )

                GeminiDeliveryPicker(store: store)

                if GeminiDeliveryPicker.isLive(store.config) {
                    Picker(selection: $store.config.geminiLiveMode) {
                        ForEach(GeminiLiveMode.allCases) { mode in
                            Text(mode.textStyleName).tag(mode)
                        }
                    } label: {
                        InfoLabel("Text style", info: "**Smart cleanup** removes disfluencies, applies spoken corrections and formats lists and numbers.\n\n**Verbatim** keeps every word as spoken.\n\nOnly Live delivery has a text style. A fixed language is sent as a hint and stays locked for the whole recording.")
                    }
                    .pickerStyle(.menu)
                }

                Text("Billed per use by Google. History shows the estimated cost of each dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                GeminiAPIKeyField(store: store)
            } header: {
                InfoLabel("API key", info: "Stored in your Keychain. Get a key at [aistudio.google.com](https://aistudio.google.com/apikey).")
            }

            VocabularySection(store: store, engine: .gemini)
        }
        .formStyle(.grouped)
    }
}

private extension GeminiLiveMode {
    /// Name in the Text style picker.
    var textStyleName: String {
        switch self {
        case .smart: "Smart cleanup"
        case .verbatim: "Verbatim"
        }
    }
}

// MARK: - Delivery choice

/// Delivery picker (Live (streaming) / After recording (batch)) for the
/// Gemini page and onboarding. It shows the engine in use while Gemini is
/// active, otherwise the one choosing Gemini will select
/// (`Config.geminiStreaming`). Choosing switches the active engine right away
/// when Gemini is already in use.
struct GeminiDeliveryPicker: View {
    @ObservedObject var store: SettingsStore

    static func isLive(_ config: Config) -> Bool {
        switch config.transcriptionEngine {
        case .geminiLive: true
        case .gemini: false
        case .whisper, .parakeet: config.geminiStreaming
        }
    }

    private var streaming: Binding<Bool> {
        Binding(
            get: { Self.isLive(store.config) },
            set: { newValue in
                store.config.geminiStreaming = newValue
                if EngineChoice(store.config.transcriptionEngine) == .gemini {
                    store.config.transcriptionEngine = newValue ? .geminiLive : .gemini
                }
            }
        )
    }

    var body: some View {
        LabeledContent {
            Picker("Delivery", selection: streaming) {
                Text("Live (streaming)").tag(true)
                Text("After recording (batch)").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        } label: {
            InfoLabel("Delivery", info: "**Live** streams audio while you talk, shows a live transcript and pastes right after you stop. If the stream fails, the recording goes through one after-recording call.\n\n**After recording** sends the whole recording once you stop and pastes in about 2 s.")
        }
    }
}
