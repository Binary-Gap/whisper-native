import SwiftUI
import WhisperNativeCore

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keyModel = GeminiKeyModel.shared
    @ObservedObject private var updater = AppUpdater.shared

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

            updatesSection
        }
        .formStyle(.grouped)
        .onAppear { keyModel.refresh() }
    }

    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: updater.currentVersion)
            if updater.isEnabled {
                LabeledToggle(
                    "Check for updates automatically",
                    help: "Check once a day. A new version shows in the status menu and here, and installs when you click Install.",
                    isOn: automaticallyChecksBinding
                )
                LabeledToggle(
                    "Install updates automatically",
                    help: "Download a new version in the background and install it the next time the app quits. Same setting as the checkbox in the update window.",
                    unavailableReason: updater.automaticallyChecks ? nil : "Needs automatic checks.",
                    isOn: automaticallyInstallsBinding
                )
                if let version = updater.availableVersion {
                    LabeledContent {
                        Button("Install…") { updater.checkForUpdates() }
                    } label: {
                        Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                    }
                } else {
                    LabeledContent {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    } label: {
                        Text(lastCheckText)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("The dev build doesn't check for updates.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheckDate else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecks },
            set: { updater.automaticallyChecks = $0 }
        )
    }

    private var automaticallyInstallsBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyInstalls },
            set: { updater.automaticallyInstalls = $0 }
        )
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
