import SwiftUI
import WhisperNativeCore

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keyModel = GeminiKeyModel.shared

    var body: some View {
        Form {
            Section {
                Picker("Transcription engine", selection: engineChoice) {
                    ForEach(EngineChoice.allCases) { choice in
                        Text(choice.pickerLabel(keyStatus: keyModel.status))
                            .tag(choice)
                            .disabled(isUnavailable(choice))
                    }
                }
                .pickerStyle(.menu)
                if let warning = keyModel.status.activeEngineWarning(engine: store.config.transcriptionEngine) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                InfoLabel("Engine", info: Self.enginesInfo)
            }

            Section("Behavior") {
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
        .onAppear { keyModel.refresh() }
    }

    // Every engine's trade-off and technical details, so the choice can be
    // made from one popover.
    private static let enginesInfo = EngineChoice.allCases
        .map { "**\($0.name)**: \($0.summary) \($0.details)" }
        .joined(separator: "\n\n")
        + "\n\nGemini uses the delivery (Live or After recording) chosen on the Gemini page."

    private func isUnavailable(_ choice: EngineChoice) -> Bool {
        choice.unavailableReason(keyStatus: keyModel.status) != nil
    }

    // One entry per engine page; Gemini selects the Streaming / Batch engine
    // remembered on the Gemini page. An unavailable choice (Gemini with no
    // key) is ignored.
    private var engineChoice: Binding<EngineChoice> {
        Binding(
            get: { EngineChoice(store.config.transcriptionEngine) },
            set: { choice in
                if let engine = EngineChoice.engineToSelect(
                    choice,
                    current: store.config.transcriptionEngine,
                    geminiStreaming: store.config.geminiStreaming,
                    keyStatus: keyModel.status
                ) {
                    store.config.transcriptionEngine = engine
                }
            }
        )
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
}
