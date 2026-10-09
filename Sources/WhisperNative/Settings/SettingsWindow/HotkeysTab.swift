import AppKit
import SwiftUI
import KeyboardShortcuts
import WhisperNativeCore

// MARK: - Hotkeys Tab

struct HotkeysTab: View {
    @ObservedObject var store: SettingsStore
    // Drives the accessibility warning and the Check button; the same published
    // flags the status-bar menu reads, so both surfaces always agree.
    @ObservedObject var hotkeyManager: HotkeyManager

    private var accessibilityWarning: Bool {
        InsertionPlan.accessibilityWarningShown(
            autoPasteWhenSameApp: store.config.autoPasteWhenSameApp,
            accessibilityGranted: hotkeyManager.accessibilityGranted,
            modifierToggleAvailable: hotkeyManager.modifierToggleAvailable
        )
    }

    // The user's languages in cycle order (set on the Language page).
    private var cycleDescription: String {
        let names = store.config.activeLanguages.map(\.displayName)
        return "Cycle language steps through your languages set on the Language page (" + names.joined(separator: " → ") + ")"
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

    var body: some View {
        Form {
            AccessibilitySection(hotkeyManager: hotkeyManager, showsWarning: accessibilityWarning, showsStatusLine: true)

            Section {
                ToggleDictationControls(store: store, showsFooter: false)
            } header: {
                InfoLabel("Toggle dictation", info: ToggleDictationControls.footer(for: store.config.toggleModifierKey))
            }

            Section {
                Picker("Key", selection: cancelKeyBinding) {
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
                InfoLabel("Cancel transcription", info: "Press once during a recording to skip auto-submit, twice to cancel the whole transcription. The key is only captured while a transcription is in progress.")
            }

            Section {
                LabeledContent("Paste last transcript") {
                    KeyboardShortcuts.Recorder("", name: .pasteLastTranscript)
                }
                LabeledContent("Cycle language") {
                    KeyboardShortcuts.Recorder("", name: .cycleLanguage)
                }
                LabeledContent("Toggle auto-start when you speak") {
                    KeyboardShortcuts.Recorder("", name: .toggleStartOnVoice)
                }
            } header: {
                InfoLabel("Other shortcuts", info: "\(cycleDescription), confirmed by an on-screen badge and the menu-bar code.\n\nToggle auto-start when you speak turns auto-start when you speak (Settings > Recording) on or off, confirmed by an on-screen badge. Turning it off cancels a recording your voice started (nothing is transcribed or pasted); a hotkey recording keeps going.\n\nClick a shortcut, then press the keys you want. Press Delete to clear it.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Accessibility section

/// Accessibility status for the Hotkeys and Output pages, fed by
/// `HotkeyManager`'s published grant and tap state (one poll for the whole
/// app). `showsWarning` renders the orange warning with Check / Open System
/// Settings; otherwise `showsStatusLine` renders a green "Accessibility
/// granted" line (or, when not granted but not needed, a secondary line with a
/// Check button), or nothing.
struct AccessibilitySection: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    let showsWarning: Bool
    let showsStatusLine: Bool

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // Re-checks the grant and tap; on failure fires the one-shot system prompt
    // and opens the Accessibility pane so the user can grant it (the prompt only
    // appears the first time, so the pane is the reliable path afterward). On
    // success the warning gives way to the green status line.
    private func checkAccessibility() {
        if !hotkeyManager.recheckAccessibility() {
            openAccessibilitySettings()
        }
    }

    var body: some View {
        if showsWarning {
            Section {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Accessibility permission needed")
                            .font(.callout.weight(.semibold))
                        Text("Accessibility is needed to paste text and use a single-key toggle. Use Check Accessibility, grant it in System Settings, then check again.")
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
        } else if showsStatusLine {
            Section {
                if hotkeyManager.accessibilityGranted {
                    Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label("Accessibility not granted, your current settings don't need it", systemImage: "circle.dashed")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Accessibility") { checkAccessibility() }
                    }
                }
            }
        }
    }
}
