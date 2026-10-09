import SwiftUI
import WhisperNativeCore

// MARK: - Output Tab

struct OutputTab: View {
    @ObservedObject var store: SettingsStore
    // Accessibility grant for the paste warning (same state as the Hotkeys page).
    @ObservedObject var hotkeyManager: HotkeyManager

    var body: some View {
        Form {
            AccessibilitySection(
                hotkeyManager: hotkeyManager,
                showsWarning: InsertionPlan.pasteNeedsAccessibility(
                    autoPasteWhenSameApp: store.config.autoPasteWhenSameApp,
                    accessibilityGranted: hotkeyManager.accessibilityGranted
                ),
                showsStatusLine: false
            )

            Section {
                Picker("After transcribing", selection: insertionStrategyBinding) {
                    Text("Paste into the active app").tag("autoPaste")
                    Text("Copy to clipboard").tag("clipboard")
                }
                .pickerStyle(.menu)

                LabeledToggle(
                    "Auto-submit in terminal (iTerm2)",
                    help: "Presses Enter after sending a transcript to an iTerm2 session.",
                    unavailableReason: autoSubmitUnavailableReason,
                    isOn: $store.config.autoSubmitInTerminal
                )
                LabeledToggle(
                    "Auto-submit in other apps",
                    help: "Presses Enter after auto-pasting a transcript into any other app (chat inputs, browsers). Pressing \(cancelKeyName) once during a recording skips it.",
                    unavailableReason: autoSubmitUnavailableReason,
                    isOn: $store.config.autoSubmitInOtherApps
                )
            } header: {
                InfoLabel("Insertion", info: "**Paste into the active app** pastes over your selection and restores the clipboard afterward.\n\n**Copy to clipboard** leaves the transcript on the clipboard for you to paste, and never auto-submits.")
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
                        // The row above already titles the slider; grouped Forms
                        // would render its label a second time.
                        .labelsHidden()
                    }
                }

                LabeledToggle(
                    "Sentence per line",
                    help: "Start each sentence on its own line, breaking after . ! or ?.",
                    isOn: $store.config.sentencePerLine
                )
                LabeledToggle(
                    "Wrap in <audio> tags",
                    help: "Wraps each transcript in <audio></audio> tags. The tags tell a chat or coding assistant (like Claude Code) that the text was spoken, so it can read past misheard words instead of taking them literally. Leave it off if you mostly dictate into documents, email or chat with people.",
                    isOn: $store.config.prependAudioTags
                )
            } header: {
                InfoLabel("Output formatting", info: "Lines break on whole words, so they land at or below the width, not exactly on it.")
            }
        }
        .formStyle(.grouped)
    }

    // Names the cancel key for help text: Esc by default, otherwise the custom shortcut.
    private var cancelKeyName: String {
        store.config.cancelKey == .escape ? "Esc" : "the cancel shortcut"
    }

    private var autoSubmitUnavailableReason: String? {
        InsertionPlan.autoSubmitUnavailableReason(autoPasteWhenSameApp: store.config.autoPasteWhenSameApp)
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
