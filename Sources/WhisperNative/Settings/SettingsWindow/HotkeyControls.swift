import AppKit
import SwiftUI
import KeyboardShortcuts
import WhisperNativeCore

// MARK: - Toggle dictation controls

/// The toggle-dictation key picker plus, for "Custom shortcut…", the chord
/// recorder. With `showsFooter` it also renders the explanatory text below;
/// Settings turns that off and shows `footer(for:)` behind its section's "?".
struct ToggleDictationControls: View {
    @ObservedObject var store: SettingsStore
    var showsFooter: Bool = true

    // Clears the recorded chord when switching away from "Custom shortcut…" so a
    // stale binding doesn't keep firing the toggle alongside a lone-modifier tap.
    private var toggleKeyBinding: Binding<ToggleModifierKey> {
        Binding(
            get: { store.config.toggleModifierKey },
            set: { newKey in
                if newKey != .custom {
                    KeyboardShortcuts.reset(.toggleDictation)
                }
                store.config.toggleModifierKey = newKey
            }
        )
    }

    /// Explains how the chosen toggle key behaves and what it requires.
    static func footer(for key: ToggleModifierKey) -> String {
        switch key {
        case .custom:
            "Click the shortcut, then press the keys you want. Press Delete to clear it."
        case .none:
            "Dictation toggle is off. Pick a lone modifier key to tap, or a custom chord shortcut."
        case .fn:
            "Tap Fn to toggle dictation. Requires Accessibility permission. Set the Globe key action to “Do Nothing” in System Settings › Keyboard so macOS doesn't intercept it."
        default:
            "Tap this modifier key to toggle dictation. Requires Accessibility permission. Left-side modifiers may fire while typing chords; right-side keys are safer."
        }
    }

    var body: some View {
        Group {
            Picker("Key", selection: toggleKeyBinding) {
                ForEach(ToggleModifierKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.menu)

            if store.config.toggleModifierKey == .custom {
                LabeledContent("Shortcut") {
                    ShortcutRecorderField(name: .toggleDictation)
                }
            }

            if showsFooter {
                Text(Self.footer(for: store.config.toggleModifierKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shortcut recorder field

/// Wraps `KeyboardShortcuts.Recorder` and, while it's actively recording, shows
/// a "Press shortcut…" hint plus an ✕ button to cancel the recording (in
/// addition to the built-in Escape / click-away). Cancelling just resigns first
/// responder on the window, which ends the recorder's capture without changing
/// any already-saved shortcut.
struct ShortcutRecorderField: View {
    let name: KeyboardShortcuts.Name
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            KeyboardShortcuts.Recorder("", name: name)

            if isRecording {
                Text("Press shortcut…")
                    .font(DesignSystem.Typography.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)

                Button {
                    // Resign first responder to end the recorder's capture.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel recording")
                .transition(.opacity)
            }
        }
        .animation(DesignSystem.Motion.snappy, value: isRecording)
        .onReceive(NotificationCenter.default.publisher(for: .recorderActiveStatusDidChange)) { note in
            isRecording = (note.userInfo?["isActive"] as? Bool) ?? false
        }
    }
}

extension Notification.Name {
    /// Posted by `KeyboardShortcuts.RecorderCocoa` when it starts/stops capturing.
    static let recorderActiveStatusDidChange = Self("KeyboardShortcuts_recorderActiveStatusDidChange")
}
