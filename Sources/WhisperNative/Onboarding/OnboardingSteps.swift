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
            StepIntro(text: "The Whisper and Parakeet engines run entirely on this Mac: audio never leaves your computer, there is no account, and they work offline once a model is downloaded. Gemini, an optional cloud engine, sends the audio to Google.")
            StepIntro(text: "It exists because typing long prompts, messages and notes is slower than saying them, and built-in dictation is either cloud-based or not accurate enough for mixed languages and technical words.")
            StepIntro(text: "This guide takes about a minute. Skip it any time; everything here also lives in Settings.")
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Engine and model

/// Same three engines as Settings > General (`EngineChoice`). Gemini can't be
/// picked until a key is saved, so while no key existed when the step opened
/// a Gemini section (mode + key field) sits below the engine's own section;
/// it stays put once a key is saved so the "Saved" confirmation is seen.
struct EngineModelStepView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var modelSectionState: ModelSectionState
    @ObservedObject private var keyModel = GeminiKeyModel.shared
    @State private var geminiKeyMissingOnAppear = false

    private var choice: EngineChoice { EngineChoice(store.config.transcriptionEngine) }

    private var engineChoice: Binding<EngineChoice> {
        Binding(
            get: { choice },
            set: { newChoice in
                if let engine = EngineChoice.engineToSelect(
                    newChoice,
                    current: store.config.transcriptionEngine,
                    geminiStreaming: store.config.geminiStreaming,
                    keyStatus: keyModel.status
                ) {
                    store.config.transcriptionEngine = engine
                }
            }
        )
    }

    var body: some View {
        FormStep(intro: "The engine is what turns audio into text. Whisper and Parakeet run locally; Gemini runs in the cloud.") {
            Section {
                Picker("Engine", selection: engineChoice) {
                    ForEach(EngineChoice.allCases) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                            Text(option.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if option.unavailableReason(keyStatus: keyModel.status) != nil {
                                Text("Add an API key in the Gemini section below to choose it.")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(option)
                        .disabled(option.unavailableReason(keyStatus: keyModel.status) != nil)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                InfoLabel("Engine", info: EngineChoice.allCases.map { "**\($0.name)**: \($0.details)" }.joined(separator: "\n\n"))
            }

            switch store.config.transcriptionEngine {
            case .whisper:
                Section {
                    whisperStatusLine
                    ModelListControls(store: store, modelState: modelSectionState)
                } header: {
                    Text("Whisper model")
                } footer: {
                    Text("The download continues if you move on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    modelSectionState.refreshAndReconcile(directory: store.config.modelsDirectory, store: store, fallBackToDownloadedModel: false)
                }
            case .parakeet:
                Section("Parakeet models") {
                    ParakeetModelControls(store: store, downloadedNotLoadedCaption: "Downloaded, loads when setup closes")
                }
            case .gemini, .geminiLive:
                geminiSection
            }

            if choice != .gemini, geminiKeyMissingOnAppear {
                geminiSection
            }
        }
        .onAppear {
            keyModel.refresh()
            geminiKeyMissingOnAppear = !keyModel.status.hasKey
        }
    }

    private var geminiSection: some View {
        Section {
            GeminiDeliveryPicker(store: store)
            GeminiAPIKeyField(store: store)
        } header: {
            Text("Gemini")
        } footer: {
            Text("The key is stored in your Keychain. Get one at aistudio.google.com. Every Gemini dictation is billed by Google.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        } else if modelSectionState.hasLocalModel {
            Label("Click Use on the model Whisper should use", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else {
            Label("No model downloaded yet, pick one below", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
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
                if !permissions.accessibilityGranted {
                    Text("In System Settings, turn on WhisperNative. If it's already on but this still says Not granted, remove it with − and add it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                LabeledContent("Toggle auto-start when you speak") {
                    ShortcutRecorderField(name: .toggleStartOnVoice)
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
        FormStep(intro: "Auto-detect works for most people. If you mix languages or it guesses wrong on short phrases, pick a fixed language. Add the languages you speak under Your languages, then switch between them with the Cycle Language hotkey while you talk; the menu-bar icon shows the current one.") {
            Section {
                LanguageControls(store: store)
            } footer: {
                switch store.config.transcriptionEngine {
                case .parakeet:
                    Text(EngineChoice.parakeet.languageCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .gemini, .geminiLive:
                    Text(EngineChoice.gemini.languageCaption)
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
                Toggle("Wrap in <audio> tags", isOn: $store.config.prependAudioTags)
            }
        }
    }
}

// MARK: - More in Settings

/// A short tour of features the earlier steps don't set up, so onboarding
/// stays short as the app grows: one line each, grouped by where it lives.
struct MoreInSettingsStepView: View {
    private struct Feature: Identifiable {
        let name: String
        let summary: String
        var id: String { name }
    }

    private let groups: [(place: String, features: [Feature])] = [
        ("Settings › Recording", [
            Feature(name: "Auto-start when you speak", summary: "Recording starts when you start talking, no key needed."),
            Feature(name: "Stop word", summary: "Say \"over\" to stop and paste (Parakeet and Gemini Live)."),
            Feature(name: "Noise suppression", summary: "Cleans up background noise and echo. On by default."),
            Feature(name: "Pause music", summary: "Pauses Apple Music while you dictate."),
        ]),
        ("Settings › Output", [
            Feature(name: "Auto-submit", summary: "Presses Return after pasting, in terminals or any app."),
            Feature(name: "Line formatting", summary: "Wrap long lines or put each sentence on its own line."),
        ]),
        ("Settings › Whisper, Gemini", [
            Feature(name: "Custom vocabulary", summary: "Names and jargon the engine should spell right."),
        ]),
        ("Settings › General", [
            Feature(name: "Updates", summary: "Checks daily; can install new versions when you quit."),
        ]),
        ("History", [
            Feature(name: "Rerun", summary: "Transcribe one of the last 50 recordings again with the current engine."),
        ]),
    ]

    var body: some View {
        FormStep(intro: "A few more things you can turn on later, no need to set them up now.") {
            ForEach(groups, id: \.place) { group in
                Section(group.place) {
                    ForEach(group.features) { feature in
                        LabeledContent(feature.name) {
                            Text(feature.summary)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Done

struct DoneStepView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var modelSectionState: ModelSectionState

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
                bullet(Text("The menu-bar icon shows the current language and opens History, Settings and this guide (Setup Guide)."))
                bullet(Text("Every transcript is saved in History, so nothing is lost if it lands in the wrong window."))
            }
            if let modelNotice {
                Label(modelNotice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Whisper is the engine but has no model to run yet: say what happens
    /// next instead of letting "You're all set" promise a working dictation.
    private var modelNotice: String? {
        guard store.config.transcriptionEngine == .whisper else { return nil }
        if modelSectionState.isDownloading {
            return "The Whisper model is still downloading. Dictation works once it finishes."
        }
        guard !modelSectionState.hasLocalModel else { return nil }
        let model = ModelManager.recommendedModel
        return "No Whisper model is downloaded yet. After Finish you'll be asked to download \(model.displayName) (\(model.approxSizeLabel)); dictation works once it's done."
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
