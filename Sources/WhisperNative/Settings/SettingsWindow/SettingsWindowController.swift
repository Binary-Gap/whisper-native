import AppKit
import SwiftUI
import WhisperNativeCore

// MARK: - SettingsWindowController

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    // Owns the sidebar selection outside SwiftUI's @State, so the page the user
    // is on survives closing and reopening the window. Only the sidebar changes it.
    private let tabSelection = SettingsTabSelection()
    // Filled in by AppDelegate after init (it needs self): the status menu's
    // Start/Stop Server action, reused by the Whisper page.
    private let actions = SettingsActions()

    /// Starts or stops the whisper daemon, same as the status menu item.
    public var onToggleServer: (@MainActor () async -> Void)? {
        get { actions.toggleServer }
        set { actions.toggleServer = newValue }
    }

    public init(store: SettingsStore, hotkeyManager: HotkeyManager, modelSectionState: ModelSectionState) {
        self.store = store
        let view = SettingsView(store: store, hotkeyManager: hotkeyManager, modelSectionState: modelSectionState, tabSelection: tabSelection, actions: actions)
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

/// The settings pages, hosted in the split-view detail pane keyed by sidebar
/// selection. File-scope (not nested in SettingsView) so
/// `SettingsTabSelection` can hold it.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, language, recording, output, hotkeys
    case whisper, parakeet, gemini

    var id: String { rawValue }

    /// Shown in the unlabeled first sidebar group.
    static let shared: [SettingsSection] = [.general, .language, .recording, .output, .hotkeys]
    /// Shown under the "Engines" sidebar heading, one page per engine.
    static let engines: [SettingsSection] = [.whisper, .parakeet, .gemini]

    var title: String {
        switch self {
        case .general: "General"
        case .language: "Language"
        case .recording: "Recording"
        case .output: "Output"
        case .hotkeys: "Hotkeys"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        case .gemini: "Gemini"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .language: "globe"
        case .recording: "mic"
        case .output: "text.alignleft"
        case .hotkeys: "keyboard"
        case .whisper: "server.rack"
        case .parakeet: "cpu"
        case .gemini: "cloud"
        }
    }

    /// The engine page that configures `engine` (both Gemini engines share one).
    static func page(for engine: TranscriptionEngine) -> SettingsSection {
        switch engine {
        case .whisper: .whisper
        case .parakeet: .parakeet
        case .gemini, .geminiLive: .gemini
        }
    }
}

/// Published sidebar selection, held outside SwiftUI's @State so
/// SettingsWindowController can drive it from the outside (e.g. force the
/// Whisper page open for a first-run model download).
@MainActor
private final class SettingsTabSelection: ObservableObject {
    @Published var section: SettingsSection = .general
}

/// App actions the pages trigger, set by AppDelegate after the window exists.
@MainActor
private final class SettingsActions {
    var toggleServer: (@MainActor () async -> Void)?
}

// MARK: - SettingsView

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    // Single source of truth for the accessibility warning: the same published
    // flag the status-bar menu reads, so both surfaces always agree.
    @ObservedObject var hotkeyManager: HotkeyManager
    // Owned by AppDelegate so a first-run/engine-switch download (started outside
    // Settings) and the Whisper page's progress bar share one downloader.
    let modelSectionState: ModelSectionState
    // Owned by SettingsWindowController so it can force a page from the outside.
    @ObservedObject var tabSelection: SettingsTabSelection
    let actions: SettingsActions

    private var accessibilityWarning: Bool {
        InsertionPlan.accessibilityWarningShown(
            autoPasteWhenSameApp: store.config.autoPasteWhenSameApp,
            accessibilityGranted: hotkeyManager.accessibilityGranted,
            modifierToggleAvailable: hotkeyManager.modifierToggleAvailable
        )
    }
    private var activeEnginePage: SettingsSection { .page(for: store.config.transcriptionEngine) }

    var body: some View {
        NavigationSplitView {
            List(selection: $tabSelection.section) {
                Section {
                    ForEach(SettingsSection.shared) { sidebarRow($0) }
                }
                Section("Engines") {
                    ForEach(SettingsSection.engines) { sidebarRow($0) }
                }
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

    private func sidebarRow(_ section: SettingsSection) -> some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
                .font(DesignSystem.Typography.rowTitle)
            Spacer()
            if section == .hotkeys && accessibilityWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
                    .help("Accessibility is needed to paste text and use a single-key toggle")
            }
            if section == activeEnginePage {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .help("Active engine")
                    .accessibilityLabel("Active engine")
            }
        }
        .tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        switch tabSelection.section {
        case .general: GeneralTab(store: store)
        case .language: LanguageTab(store: store)
        case .recording: RecordingTab(store: store)
        case .output: OutputTab(store: store, hotkeyManager: hotkeyManager)
        case .hotkeys: HotkeysTab(store: store, hotkeyManager: hotkeyManager)
        case .whisper: WhisperPage(store: store, modelState: modelSectionState, onToggleServer: actions.toggleServer)
        case .parakeet: ParakeetPage(store: store)
        case .gemini: GeminiPage(store: store)
        }
    }
}
