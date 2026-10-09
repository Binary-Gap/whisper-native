import SwiftUI
import WhisperNativeCore

// MARK: - Whisper page

/// Settings > Engines > Whisper: everything only the whisper.cpp daemon reads.
/// Model choice first, then transcription options, custom vocabulary
/// (`words.yml`, shared with Gemini) and voice calibration, then
/// an Advanced section (server status, VAD model). Editable whichever engine
/// is active; changes reach the daemon once whisper is selected (AppDelegate
/// reloads it with the current model and VAD).
struct WhisperPage: View {
    @ObservedObject var store: SettingsStore
    // Shared with AppDelegate (not locally owned): a model download agreed to
    // on an engine switch is kicked off outside Settings, and this page just
    // observes its progress rather than running a second, independent downloader.
    @ObservedObject var modelState: ModelSectionState
    /// Same action as the status menu's Start/Stop Server.
    let onToggleServer: (@MainActor () async -> Void)?

    private var whisperActive: Bool { store.config.transcriptionEngine == .whisper }

    var body: some View {
        Form {
            Section {
                EngineActivationRow(store: store, engine: .whisper)
            }

            Section {
                if whisperActive, !modelState.isDownloading, !ModelStorage.isFileDownloaded(store.config.modelPath) {
                    Label("No model in use, so Whisper can't transcribe. Download a model below, or click Use on a downloaded one.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                    modelState.refreshAndReconcile(directory: newDir, store: store, fallBackToDownloadedModel: true)
                }
            } header: {
                InfoLabel("Whisper models", info: "Bigger models are more accurate but slower and use more memory. Downloading a model doesn't switch to it: click Use on the one you want.")
            }

            Section("Transcription") {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    InfoLabel("Initial prompt", info: "Text Whisper treats as what came before the dictation, so it copies its spelling, punctuation and style. Write it like a transcript, not instructions. Optional.\n\nWhisper's prompt is the built-in example sentence (English and Portuguese only), then this text, then the custom vocabulary terms. This text is always kept whole; a long one leaves less room for terms.")
                        .font(DesignSystem.Typography.rowTitle)
                    SettingsTextBox(minContentHeight: 48) {
                        GrowingTextField(text: $store.config.prompt, font: .system(.body, design: .monospaced))
                    }
                }
                LabeledToggle(
                    "Translate to English",
                    help: "Transcribe non-English speech, then translate the result.",
                    isOn: $store.config.translateToEnglish
                )
            }

            VocabularySection(store: store, engine: .whisper)

            VoiceCalibrationSection(store: store)

            Section {
                WhisperServerStatusRow(store: store, modelState: modelState, onToggleServer: onToggleServer)
                VadModelControls(store: store, modelState: modelState)
            } header: {
                InfoLabel("Advanced", info: "**Server**: keeps the model loaded so dictation starts instantly. It runs only while Whisper is the active engine and stops when you quit the app.\n\n**Voice activity detection**: trims silence before transcription. Downloaded with the first Whisper model.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            modelState.refreshAndReconcile(directory: store.config.modelsDirectory, store: store, fallBackToDownloadedModel: false)
        }
    }

    private var modelsDirectoryBinding: Binding<URL> {
        Binding(
            get: { store.config.modelsDirectory },
            set: { store.config.modelsDirectory = $0 }
        )
    }
}

// MARK: - Server status row

/// Daemon health pill (GET /health, polled every few seconds while visible),
/// a re-check button and Start/Stop Server. The pill reads neutral while
/// another engine is active (the daemon is meant to be down then) and red only
/// when Whisper is active and the daemon is down. Start/Stop is enabled only
/// while whisper is the active engine and no model download is running; its
/// tooltip says why when disabled.
private struct WhisperServerStatusRow: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var modelState: ModelSectionState
    let onToggleServer: (@MainActor () async -> Void)?

    @State private var health: WhisperServerHealth = .checking
    @State private var isTogglingServer = false

    // How often the pill re-reads /health while the page is visible, and how
    // long Start/Stop waits for the daemon to come up (model load) or go down.
    private static let pollInterval: Duration = .seconds(3)
    private static let toggleWaitSeconds = 20

    private var whisperActive: Bool { store.config.transcriptionEngine == .whisper }

    private var display: WhisperServerDisplay {
        WhisperServerDisplay.resolve(
            health: health,
            isWhisperActive: whisperActive,
            toggle: isTogglingServer ? (health == .running ? .stopping : .starting) : nil
        )
    }

    private var toggleBlockedReason: String? {
        if onToggleServer == nil { return "Not available here." }
        return WhisperServerDisplay.toggleBlockedReason(
            isWhisperActive: whisperActive,
            isDownloading: modelState.isDownloading,
            health: health,
            isToggling: isTogglingServer
        )
    }

    var body: some View {
        LabeledContent("Server") {
            HStack(spacing: DesignSystem.Spacing.sm) {
                statusPill

                Button {
                    Task { await checkServerStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: health == .checking)
                }
                .buttonStyle(.borderless)
                .help("Re-check server status")
                .disabled(health == .checking || isTogglingServer)

                // A disabled button shows no tooltip of its own, so the reason
                // sits on an enabled wrapper.
                HStack(spacing: 0) {
                    Button(health == .running ? "Stop Server" : "Start Server") {
                        Task { await toggleServer() }
                    }
                    .disabled(toggleBlockedReason != nil)
                }
                .contentShape(Rectangle())
                .help(toggleBlockedReason ?? (health == .running ? "Stop the Whisper server" : "Start the Whisper server"))
            }
        }
        // Restarts on an engine switch, which boots the daemon in or out.
        .task(id: store.config.transcriptionEngine) {
            await checkServerStatus()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, !isTogglingServer else { continue }
                health = await store.checkServerAvailable() ? .running : .stopped
            }
        }
    }

    private var statusPill: some View {
        let display = display
        let color = Self.color(for: display.tone)
        return HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: display.tone == .neutral ? .clear : color.opacity(0.6), radius: 3)
            Text(display.label)
                .font(DesignSystem.Typography.metadata)
                .foregroundStyle(display.tone == .neutral ? .secondary : .primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .animation(DesignSystem.Motion.smooth, value: display)
    }

    private static func color(for tone: StatusTone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .good: .green
        case .pending: .yellow
        case .problem: .red
        }
    }

    private func checkServerStatus() async {
        health = .checking
        health = await store.checkServerAvailable() ? .running : .stopped
    }

    private func toggleServer() async {
        guard let onToggleServer else { return }
        let wasRunning = health == .running
        isTogglingServer = true
        defer { isTogglingServer = false }
        await onToggleServer()
        // Wait for /health to flip: a start loads the model for a few seconds.
        for _ in 0..<Self.toggleWaitSeconds {
            let running = await store.checkServerAvailable()
            health = running ? .running : .stopped
            if running != wasRunning { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
