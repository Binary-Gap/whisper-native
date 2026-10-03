import AppKit
import SwiftUI
import KeyboardShortcuts
import WhisperNativeCore

// MARK: - Hotkeys Tab

struct HotkeysTab: View {
    @ObservedObject var store: SettingsStore
    // Drives the accessibility warning and the Check button; the same published
    // flag the status-bar menu reads, so both surfaces always agree.
    @ObservedObject var hotkeyManager: HotkeyManager

    // Brief green confirmation shown after a successful accessibility check.
    @State private var checkPassed = false

    private var accessibilityWarning: Bool { !hotkeyManager.modifierToggleAvailable }

    // The user's cycle order (picked in General > Language).
    private var cycleDescription: String {
        let names = store.config.cycleLanguages.map(\.displayName)
        if names.isEmpty { return "No languages are picked for cycling (General > Language)" }
        return "Cycling goes " + names.joined(separator: " → ")
    }

    // Applies the chosen cancel binding. `.escape` sets the shortcut to a bare
    // Escape (which the recorder UI can't display, hence the picker); `.custom`
    // clears it so the user records their own chord.
    private var cancelKeyBinding: Binding<CancelKey> {
        Binding(
            get: { store.config.cancelKey },
            set: { newKey in
                switch newKey {
                case .escape:
                    KeyboardShortcuts.setShortcut(.init(.escape), for: .cancelTranscription)
                case .custom:
                    KeyboardShortcuts.reset(.cancelTranscription)
                }
                // setShortcut/reset re-register (re-enable) the shortcut. Nothing is
                // recording while Settings is open, so keep the cancel key gated
                // closed; the Orchestrator re-enables it for the next recording.
                KeyboardShortcuts.disable(.cancelTranscription)
                store.config.cancelKey = newKey
            }
        )
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // Re-checks the tap; on success flashes a green confirmation, otherwise fires
    // the one-shot system prompt and opens the Accessibility pane so the user can
    // grant it (the prompt only appears the first time, so the pane is the reliable
    // path afterward).
    private func checkAccessibility() {
        if hotkeyManager.requestAccessibilityIfNeeded() {
            withAnimation(DesignSystem.Motion.snappy) { checkPassed = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(DesignSystem.Motion.snappy) { checkPassed = false }
            }
        } else {
            openAccessibilitySettings()
        }
    }

    var body: some View {
        Form {
            if accessibilityWarning {
                Section {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .symbolRenderingMode(.hierarchical)
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Accessibility permission needed")
                                .font(.callout.weight(.semibold))
                            Text("The single-key toggle can't run until Accessibility is granted. Use Check Accessibility, grant it in System Settings, then check again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Button("Check Accessibility") { checkAccessibility() }
                                Button("Open System Settings") { openAccessibilitySettings() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Section {
                    Button { checkAccessibility() } label: {
                        Label(
                            checkPassed ? "Accessibility OK" : "Check Accessibility",
                            systemImage: checkPassed ? "checkmark.circle.fill" : "checkmark.shield"
                        )
                        .foregroundStyle(checkPassed ? Color.green : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                    }
                } footer: {
                    Text("Verifies the single-key toggle can capture keys. Only needed if a lone modifier key is set as the toggle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ToggleDictationControls(store: store, showsFooter: false)
            } header: {
                Text("Toggle dictation")
            } footer: {
                Text(ToggleDictationControls.footer(for: store.config.toggleModifierKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Cancel transcription", selection: cancelKeyBinding) {
                    ForEach(CancelKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .pickerStyle(.menu)

                if store.config.cancelKey == .custom {
                    LabeledContent("Shortcut") {
                        ShortcutRecorderField(name: .cancelTranscription)
                            // Recording a chord re-registers (re-enables) the
                            // shortcut. Re-gate it closed once capture ends so the
                            // key doesn't fire globally while nothing is recording.
                            .onReceive(NotificationCenter.default.publisher(for: .recorderActiveStatusDidChange)) { note in
                                let isActive = (note.userInfo?["isActive"] as? Bool) ?? false
                                if !isActive {
                                    KeyboardShortcuts.disable(.cancelTranscription)
                                }
                            }
                    }
                }
            } header: {
                Text("Cancel transcription")
            } footer: {
                Text("Press once during a recording to skip auto-submit, twice to cancel the whole transcription. The key is only captured while a transcription is in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Paste last transcript") {
                    KeyboardShortcuts.Recorder("", name: .pasteLastTranscript)
                }
                LabeledContent("Cycle language") {
                    KeyboardShortcuts.Recorder("", name: .cycleLanguage)
                }
            } header: {
                Text("Other shortcuts")
            } footer: {
                Text("\(cycleDescription), confirmed by an on-screen badge and the menu-bar code. Click a shortcut, then press the keys you want. Press Delete to clear it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
