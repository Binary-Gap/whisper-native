import SwiftUI
import WhisperNativeCore

// MARK: - Transcription Tab

struct TranscriptionTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Insertion strategy", selection: insertionStrategyBinding) {
                    Text("Auto-paste into focused app").tag("autoPaste")
                    Text("Copy to clipboard only").tag("clipboard")
                }
                .pickerStyle(.menu)

                LabeledToggle(
                    "Prepend <audio> tags",
                    help: "Wraps each transcript in <audio></audio> markers.",
                    isOn: $store.config.prependAudioTags
                )
                LabeledToggle(
                    "Translate to English",
                    help: "Transcribe non-English speech, then translate the result.",
                    isOn: $store.config.translateToEnglish
                )
                LabeledToggle(
                    "Auto-submit in terminal (iTerm2)",
                    help: "Presses Enter after sending a transcript to an iTerm2 session.",
                    isOn: $store.config.autoSubmitInTerminal
                )
                LabeledToggle(
                    "Auto-submit in other apps",
                    help: "Presses Enter after auto-pasting a transcript into any other app (chat inputs, browsers). Esc once during a recording skips it.",
                    isOn: $store.config.autoSubmitInOtherApps
                )
            } header: {
                Text("Insertion")
            } footer: {
                Text("Auto-paste pastes over your selection and restores the clipboard afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledToggle(
                    "Wrap lines",
                    help: "Break the transcript into lines at word boundaries, capped at the width below.",
                    isOn: $store.config.lineWrapEnabled
                )

                if store.config.lineWrapEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Line width")
                            Spacer()
                            Text("\(store.config.lineWrapWidth) chars")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: lineWrapWidthBinding,
                            in: 20...100,
                            step: 1
                        ) {
                            Text("Line width")
                        } minimumValueLabel: {
                            Text("20").font(.caption).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("100").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledToggle(
                    "Sentence per line",
                    help: "Start each sentence on its own line, breaking after . ! or ?.",
                    isOn: $store.config.sentencePerLine
                )
            } header: {
                Text("Output formatting")
            } footer: {
                Text("Lines break on whole words, so they land at or below the width, not exactly on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsTextBox(minContentHeight: 48) {
                    GrowingTextField(text: $store.config.prompt, font: .system(.body, design: .monospaced))
                }
            } header: {
                Text("Initial prompt")
            } footer: {
                Text("Biases the model toward specific spellings or vocabulary. Leave empty to use per-language defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // Maps the auto-paste boolean to a two-option picker tag.
    private var insertionStrategyBinding: Binding<String> {
        Binding(
            get: { store.config.autoPasteWhenSameApp ? "autoPaste" : "clipboard" },
            set: { store.config.autoPasteWhenSameApp = ($0 == "autoPaste") }
        )
    }

    // Slider works in Double; bridge to the Int-backed config field.
    private var lineWrapWidthBinding: Binding<Double> {
        Binding(
            get: { Double(store.config.lineWrapWidth) },
            set: { store.config.lineWrapWidth = Int($0.rounded()) }
        )
    }
}
