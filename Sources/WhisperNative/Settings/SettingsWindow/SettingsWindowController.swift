import AppKit
import SwiftUI
import WhisperNativeCore

// MARK: - SettingsWindowController

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    // Owns the sidebar selection outside SwiftUI's @State so a caller (e.g. a
    // first-run model download) can force the window onto a specific tab even
    // when it's already open on another one.
    private let tabSelection = SettingsTabSelection()

    public init(store: SettingsStore, hotkeyManager: HotkeyManager, modelSectionState: ModelSectionState) {
        self.store = store
        let view = SettingsView(store: store, hotkeyManager: hotkeyManager, modelSectionState: modelSectionState, tabSelection: tabSelection)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Whisper Native Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 600))
        window.center()
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        // Force a Dock icon while Settings is open so the window is Cmd-Tabbable
        // and reachable even when the app normally runs menu-bar-only. Restored
        // to the user's baseline in windowWillClose.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Deny initial keyboard focus to the first text field (models directory):
        // AppKit consults initialFirstResponder when the window becomes key, so
        // pinning it to nil lands the window focus-free without racing SwiftUI's
        // own focus pass.
        window?.initialFirstResponder = nil
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Opens Settings pinned to the General tab, even if the window was already
    /// open on a different one (used by the first-run model download so the
    /// user lands on the progress bar, not wherever they last left the window).
    public func showGeneralTab() {
        tabSelection.section = .general
        show()
    }

    public func windowWillClose(_ notification: Notification) {
        Self.applyBaselineActivationPolicy(store.config)
    }

    /// Sets the app's activation policy to the user's baseline: a Dock icon
    /// (.regular) when `showDockIcon` is on, otherwise menu-bar-only (.accessory).
    /// Call at launch and whenever the Settings window closes.
    public static func applyBaselineActivationPolicy(_ config: Config) {
        NSApp.setActivationPolicy(config.showDockIcon ? .regular : .accessory)
    }
}

// MARK: - Settings sections

/// The settings sections, hosted in the split-view detail pane keyed by
/// sidebar selection. Presentation-only replacement for the old TabView.
/// File-scope (not nested in SettingsView) so SettingsWindowController can
/// name `.general` when forcing the tab selection.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, audio, transcription, hotkeys, server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .transcription: "Transcription"
        case .hotkeys: "Hotkeys"
        case .server: "Server"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .audio: "waveform"
        case .transcription: "text.alignleft"
        case .hotkeys: "keyboard"
        case .server: "network"
        }
    }
}

/// Published sidebar selection, held outside SwiftUI's @State so
/// SettingsWindowController can drive it from the outside (e.g. force the
/// General tab open for a first-run model download).
@MainActor
private final class SettingsTabSelection: ObservableObject {
    @Published var section: SettingsSection = .general
}

// MARK: - SettingsView

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    // Single source of truth for the accessibility warning: the same published
    // flag the status-bar menu reads, so both surfaces always agree.
    @ObservedObject var hotkeyManager: HotkeyManager
    // Owned by AppDelegate so a first-run/engine-switch download (started outside
    // Settings) and the General tab's progress bar share one downloader.
    let modelSectionState: ModelSectionState
    // Owned by SettingsWindowController so it can force a tab from the outside.
    @ObservedObject var tabSelection: SettingsTabSelection

    private var accessibilityWarning: Bool { !hotkeyManager.modifierToggleAvailable }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $tabSelection.section) { section in
                HStack {
                    Label(section.title, systemImage: section.symbol)
                        .font(DesignSystem.Typography.rowTitle)
                    if section == .hotkeys && accessibilityWarning {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .symbolRenderingMode(.hierarchical)
                            .help("Accessibility permission needed for the single-key toggle")
                    }
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            detail
                .navigationTitle(tabSelection.section.title)
                .animation(DesignSystem.Motion.smooth, value: tabSelection.section)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 560)
        // Changing the toggle-key choice in Settings reinstalls the tap so the
        // published availability flag (and thus the warning) updates immediately,
        // rather than waiting for the next app activation.
        .onChange(of: store.config.toggleModifierKey) { _, _ in
            hotkeyManager.refreshModifierTap()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch tabSelection.section {
        case .general: GeneralTab(store: store, modelState: modelSectionState)
        case .audio: AudioTab(store: store)
        case .transcription: TranscriptionTab(store: store)
        case .hotkeys: HotkeysTab(store: store, hotkeyManager: hotkeyManager)
        case .server: ServerTab(store: store)
        }
    }
}
