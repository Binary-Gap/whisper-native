import AppKit
import SwiftUI
import KeyboardShortcuts
import WhisperNativeCore

// Step bodies for the onboarding window. The container (OnboardingView) owns the
// title header and the Back/Next/Skip bar, so each view renders only its
// explanation and controls. Every control writes straight to `store.config`.

// MARK: - Shared helpers

/// The explanatory paragraph at the top of a step.
private struct StepIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small status chip ("Granted", "Not granted", "Downloaded", ...).
private struct StatusBadge: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}

/// Intro paragraph above a grouped Form, the layout shared by every step with controls.
private struct FormStep<Content: View>: View {
    let intro: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(text: intro)
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.top, DesignSystem.Spacing.lg)
            Form {
                content()
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Welcome

struct WelcomeStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.lg) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Welcome to Whisper Native")
                    .font(.title.weight(.semibold))
            }
            StepIntro(text: "Whisper Native turns speech into text anywhere on your Mac. Tap a key, talk, tap again, and the text is typed where your cursor is.")
            StepIntro(text: "Everything runs on this Mac. Audio never leaves your computer, there is no account, and it works offline once a model is downloaded.")
            StepIntro(text: "It exists because typing long prompts, messages and notes is slower than saying them, and built-in dictation is either cloud-based or not accurate enough for mixed languages and technical words.")
            StepIntro(text: "This guide takes about a minute. Skip it any time; everything here also lives in Settings.")
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Engine and model

struct EngineModelStepView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var modelSectionState: ModelSectionState

    @State private var parakeetState: ParakeetLoadState = .notLoaded

    var body: some View {
        FormStep(intro: "The engine is what turns audio into text. Whisper and Parakeet run locally; Gemini is a cloud experiment.") {
            Section("Engine") {
                Picker("Engine", selection: $store.config.transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                            Text(Self.caption(for: engine))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            switch store.config.transcriptionEngine {
            case .whisper:
                Section {
                    whisperStatusLine
                    ModelListControls(store: store, modelState: modelSectionState)
                } header: {
                    Text("Whisper model")
                } footer: {
                    Text("The download continues if you move on. Large v3 Turbo is the recommended default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    modelSectionState.refreshAndReconcile(directory: store.config.modelsDirectory, store: store)
                }
            case .parakeet:
                Section("Parakeet model") {
                    parakeetStatusLine
                }
                .task {
                    while !Task.isCancelled {
                        parakeetState = await ParakeetBackend.shared.loadState()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            case .gemini, .geminiLive:
                Section {
                    GeminiAPIKeyField()
                } header: {
                    Text("Gemini API key")
                } footer: {
                    Text("Stored in your Keychain. Get a key at aistudio.google.com.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func caption(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .whisper:
            "Best accuracy, ~100 languages, custom vocabulary prompt. Runs as a background server so it stays warm."
        case .parakeet:
            "Faster, shows a live transcript while you talk, 25 European languages. Model downloads on first use (~500 MB)."
        case .gemini:
            "Experimental cloud engine: sends audio to Google's Gemini API. Needs an API key and internet, 85+ languages."
        case .geminiLive:
            "Experimental cloud engine: streams audio to Google's Gemini Live API and shows a live transcript while you talk. Needs an API key and internet."
        }
    }

    @ViewBuilder
    private var whisperStatusLine: some View {
        if modelSectionState.isDownloading {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Downloading… \(Int((modelSectionState.downloadProgress * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            }
        } else if FileManager.default.isReadableFile(atPath: store.config.modelPath.path) {
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("No model downloaded yet, pick one below", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var parakeetStatusLine: some View {
        switch parakeetState {
        case .notLoaded:
            HStack {
                if ParakeetBackend.modelsDownloaded {
                    Label("Downloaded, loads when setup closes", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    loadParakeetButton("Load now")
                } else {
                    Label("Not downloaded yet (~500 MB)", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    loadParakeetButton("Download")
                }
            }
        case .loading:
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(ParakeetBackend.modelsDownloaded ? "Loading…" : "Downloading… (takes a minute)")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                loadParakeetButton("Retry")
            }
        }
    }

    // The engine itself starts when onboarding closes; this only fetches and
    // warms the model early so the first dictation is instant.
    private func loadParakeetButton(_ title: String) -> some View {
        Button(title) {
            parakeetState = .loading
            Task {
                do {
                    try await ParakeetBackend.shared.preload()
                } catch {
                    AppLogger.shared.log(.error, "Parakeet preload from onboarding failed: \(error)")
                }
                parakeetState = await ParakeetBackend.shared.loadState()
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsStepView: View {
    @ObservedObject var permissions: PermissionsState

    var body: some View {
        FormStep(intro: "Whisper Native needs two permissions. Both stay on this Mac.") {
            Section {
                permissionRow(
                    title: "Microphone",
                    caption: "To hear you. Recording only happens while dictation is on.",
                    isGranted: permissions.microphone == .granted
                ) {
                    switch permissions.microphone {
                    case .granted:
                        EmptyView()
                    case .notDetermined:
                        Button("Allow Microphone") { permissions.requestMicrophone() }
                    case .denied:
                        Button("Open Settings") { permissions.openMicrophoneSettings() }
                    }
                }
            }

            Section {
                permissionRow(
                    title: "Accessibility",
                    caption: "To type the text into other apps (it pastes with Cmd+V) and to catch a single modifier key like Fn as the dictation hotkey. Without it, the text is only copied to the clipboard.",
                    isGranted: permissions.accessibilityGranted
                ) {
                    if !permissions.accessibilityGranted {
                        Button("Grant Accessibility") { permissions.promptAccessibility() }
                    }
                }
                Text("In System Settings, turn on WhisperNative. If it's already on but this still says Not granted, remove it with − and add it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { permissions.startMonitoring() }
        .onDisappear { permissions.stopMonitoring() }
    }

    private func permissionRow<Action: View>(
        title: String,
        caption: String,
        isGranted: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(title).font(DesignSystem.Typography.sectionTitle)
                    if isGranted {
                        StatusBadge(systemImage: "checkmark.circle.fill", text: "Granted", color: .green)
                    } else {
                        StatusBadge(systemImage: "xmark.circle.fill", text: "Not granted", color: .orange)
                    }
                }
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            action()
        }
    }
}

// MARK: - Hotkeys

struct HotkeysStepView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        FormStep(intro: "Tap the dictation key once to start recording and again to stop. The text appears where your cursor is.") {
            Section("Dictation") {
                ToggleDictationControls(store: store)
            }

            Section {
                // The cancel key choice itself stays in Settings › Hotkeys, which
                // owns the gating between Escape and a custom chord.
                if store.config.cancelKey == .escape {
                    LabeledContent("Cancel") {
                        Text("Esc once skips auto-submit, twice cancels")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Cancel") {
                        ShortcutRecorderField(name: .cancelTranscription)
                    }
                }
                Text("Change it in Settings › Hotkeys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("While recording")
            }

            Section {
                LabeledContent("Paste last transcript") {
                    ShortcutRecorderField(name: .pasteLastTranscript)
                }
                LabeledContent("Cycle language") {
                    ShortcutRecorderField(name: .cycleLanguage)
                }
            } header: {
                Text("Anytime")
            } footer: {
                Text("Click a shortcut and press new keys to change it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Language

struct LanguageStepView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        FormStep(intro: "Auto-detect works for most people. If you mix languages or it guesses wrong on short phrases, pick a fixed language. Add the languages you use to the cycle, then switch between them with the Cycle Language hotkey while you talk; the menu-bar icon shows the current one.") {
            Section {
                LanguageControls(store: store)
            } footer: {
                switch store.config.transcriptionEngine {
                case .parakeet:
                    Text("Parakeet always auto-detects; the language only narrows which alphabet it uses.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .gemini, .geminiLive:
                    Text("Gemini auto-detects; a fixed language is sent as a hint.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .whisper:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Audio tags

struct AudioTagsStepView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        FormStep(intro: "Optional, for talking to AI assistants. When on, each transcript is wrapped like this:") {
            Section {
                Text(Constants.wrapWithAudioTags("refactor the parser to use the new tokenizer"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.card, style: .continuous)
                            .fill(.quaternary)
                    )
                StepIntro(text: "The tags tell a chat or coding assistant (like Claude Code) that the text was spoken, so it can read past misheard words instead of taking them literally. Leave it off if you mostly dictate into documents, email or chat with people.")
            }

            Section {
                Toggle("Wrap transcripts in <audio> tags", isOn: $store.config.prependAudioTags)
            }
        }
    }
}

// MARK: - Done

struct DoneStepView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("You're all set")
                    .font(.title.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                bullet(hotkeyLine)
                bullet(Text("The menu-bar icon shows the current language and opens History, Settings and this guide (Setup Guide…)."))
                bullet(Text("Every transcript is saved in History, so nothing is lost if it lands in the wrong window."))
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hotkeyLine: Text {
        switch store.config.toggleModifierKey {
        case .none:
            Text("No dictation hotkey is set, pick one in Settings › Hotkeys.")
        case .custom:
            Text("Tap \(Text("your shortcut").bold()) to start and stop dictation.")
        default:
            Text("Tap \(Text(store.config.toggleModifierKey.displayName).bold()) to start and stop dictation.")
        }
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
