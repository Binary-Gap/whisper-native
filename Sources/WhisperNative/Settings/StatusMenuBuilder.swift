import AppKit
import WhisperNativeCore

@MainActor
public final class StatusMenuBuilder {
    private let onShowSettings: @MainActor () -> Void
    private let onShowHistory: @MainActor () -> Void
    private let onShowOnboarding: @MainActor () -> Void
    private let onToggleServer: @MainActor () -> Void
    private let onSelectInputDevice: @MainActor (String?) -> Void
    private let onQuit: @MainActor () -> Void

    // Retained so NSMenu can call back to us as its delegate target.
    private var settingsItem: NSMenuItem?
    private var historyItem: NSMenuItem?
    private var serverStatusItem: NSMenuItem?
    private var serverToggleItem: NSMenuItem?
    private var modelItem: NSMenuItem?
    private var micItem: NSMenuItem?

    // Retained so NSMenuItem's weak `target` stays alive as long as the menu;
    // otherwise items auto-disable (gray out) when AppKit can't validate them.
    private var actionTarget: ActionTarget?
    // One target per mic submenu item (each needs its own captured UID).
    private var micActionTargets: [MicSelectionTarget] = []

    public init(
        onShowSettings: @escaping @MainActor () -> Void,
        onShowHistory: @escaping @MainActor () -> Void,
        onShowOnboarding: @escaping @MainActor () -> Void,
        onToggleServer: @escaping @MainActor () -> Void,
        onSelectInputDevice: @escaping @MainActor (String?) -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onShowSettings = onShowSettings
        self.onShowHistory = onShowHistory
        self.onShowOnboarding = onShowOnboarding
        self.onToggleServer = onToggleServer
        self.onSelectInputDevice = onSelectInputDevice
        self.onQuit = onQuit
    }

    public func buildMenu(accessibilityWarning: Bool = false) -> NSMenu {
        let menu = NSMenu()
        // AppKit auto-enables items whose target responds to the action selector,
        // overriding any isEnabled we set below (e.g. disabling the server toggle
        // while a model download is in flight). Every item here defaults to
        // enabled anyway, so turning this off changes nothing except making our
        // explicit isEnabled assignments actually stick.
        menu.autoenablesItems = false

        let target = ActionTarget(
            onSettings: onShowSettings,
            onHistory: onShowHistory,
            onOnboarding: onShowOnboarding,
            onToggleServer: onToggleServer,
            onQuit: onQuit
        )
        actionTarget = target

        // Accessibility warning — shown when the single-key toggle can't install its
        // event tap (missing/stale grant). Clicking opens the Accessibility pane.
        if accessibilityWarning {
            let warning = NSMenuItem(
                title: "⚠ Accessibility needed for single-key toggle",
                action: #selector(ActionTarget.openAccessibilitySettingsAction),
                keyEquivalent: ""
            )
            warning.target = target
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        // History (primary window — listed first)
        let history = NSMenuItem(
            title: "History…",
            action: #selector(ActionTarget.historyAction),
            keyEquivalent: "y"
        )
        history.target = target
        menu.addItem(history)
        historyItem = history

        // Settings
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(ActionTarget.settingsAction),
            keyEquivalent: ","
        )
        settings.target = target
        menu.addItem(settings)
        settingsItem = settings

        // Setup Guide: reopens the onboarding window at its first step.
        let setupGuide = NSMenuItem(
            title: "Setup Guide…",
            action: #selector(ActionTarget.onboardingAction),
            keyEquivalent: ""
        )
        setupGuide.target = target
        menu.addItem(setupGuide)

        menu.addItem(.separator())

        // Microphone submenu
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu()
        mic.submenu = micSubmenu
        menu.addItem(mic)
        micItem = mic

        menu.addItem(.separator())

        // Server status (static label)
        let statusItem = NSMenuItem(title: "Server: Stopped", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        serverStatusItem = statusItem

        // Start/Stop server toggle
        let toggleItem = NSMenuItem(
            title: "Start Server",
            action: #selector(ActionTarget.serverToggleAction),
            keyEquivalent: ""
        )
        toggleItem.target = target
        menu.addItem(toggleItem)
        serverToggleItem = toggleItem

        menu.addItem(.separator())

        // Current model
        let model = NSMenuItem(title: "Model: —", action: nil, keyEquivalent: "")
        model.isEnabled = false
        menu.addItem(model)
        modelItem = model

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(ActionTarget.quitAction),
            keyEquivalent: "q"
        )
        quit.target = target
        menu.addItem(quit)

        return menu
    }

    public func rebuild(
        serverRunning: Bool,
        modelName: String,
        inputDevices: [AudioInputDevice],
        selectedInputDeviceUID: String?,
        accessibilityWarning: Bool = false,
        downloadingModel: Bool = false,
        whisperEngineActive: Bool = true
    ) -> NSMenu {
        let menu = buildMenu(accessibilityWarning: accessibilityWarning)
        applyDynamicState(
            serverRunning: serverRunning,
            modelName: modelName,
            inputDevices: inputDevices,
            selectedInputDeviceUID: selectedInputDeviceUID,
            downloadingModel: downloadingModel,
            whisperEngineActive: whisperEngineActive
        )
        return menu
    }

    // MARK: Private helpers

    private func applyDynamicState(
        serverRunning: Bool,
        modelName: String,
        inputDevices: [AudioInputDevice],
        selectedInputDeviceUID: String?,
        downloadingModel: Bool,
        whisperEngineActive: Bool
    ) {
        // A first-run/engine-switch model download is in flight: the daemon isn't
        // bootstrapped yet (it would just crash-loop against the missing model), so
        // show that state instead of "Stopped" and don't offer to start it.
        serverStatusItem?.title = downloadingModel
            ? "Server: Downloading model…"
            : (serverRunning ? "Server: Running" : "Server: Stopped")
        serverToggleItem?.title = serverRunning ? "Stop Server" : "Start Server"
        // Parakeet and Gemini keep the whisper daemon booted out; toggling it on
        // would just kick off a (possibly 1.6 GB) model download for a daemon
        // that never gets used while either stays selected.
        serverToggleItem?.isEnabled = !downloadingModel && whisperEngineActive
        modelItem?.title = "Model: \(modelName)"
        rebuildMicSubmenu(inputDevices: inputDevices, selectedInputDeviceUID: selectedInputDeviceUID)
    }

    private func rebuildMicSubmenu(inputDevices: [AudioInputDevice], selectedInputDeviceUID: String?) {
        guard let submenu = micItem?.submenu else { return }
        submenu.removeAllItems()
        micActionTargets.removeAll()

        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(MicSelectionTarget.selectAction),
            keyEquivalent: ""
        )
        let defaultTarget = MicSelectionTarget(uid: nil, onSelect: onSelectInputDevice)
        defaultItem.target = defaultTarget
        defaultItem.state = selectedInputDeviceUID == nil ? .on : .off
        micActionTargets.append(defaultTarget)
        submenu.addItem(defaultItem)

        if !inputDevices.isEmpty {
            submenu.addItem(.separator())
        }

        for device in inputDevices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(MicSelectionTarget.selectAction),
                keyEquivalent: ""
            )
            let deviceTarget = MicSelectionTarget(uid: device.uid, onSelect: onSelectInputDevice)
            item.target = deviceTarget
            item.state = selectedInputDeviceUID == device.uid ? .on : .off
            micActionTargets.append(deviceTarget)
            submenu.addItem(item)
        }
    }
}

// MARK: - ActionTarget

// NSMenuItem requires an ObjC-compatible target. This thin object bridges
// @MainActor closures to @objc selectors.
@MainActor
private final class ActionTarget: NSObject {
    private let onSettings: @MainActor () -> Void
    private let onHistory: @MainActor () -> Void
    private let onOnboarding: @MainActor () -> Void
    private let onToggleServer: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    init(
        onSettings: @escaping @MainActor () -> Void,
        onHistory: @escaping @MainActor () -> Void,
        onOnboarding: @escaping @MainActor () -> Void,
        onToggleServer: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onSettings = onSettings
        self.onHistory = onHistory
        self.onOnboarding = onOnboarding
        self.onToggleServer = onToggleServer
        self.onQuit = onQuit
    }

    @objc func settingsAction() {
        onSettings()
    }

    @objc func historyAction() {
        onHistory()
    }

    @objc func onboardingAction() {
        onOnboarding()
    }

    @objc func serverToggleAction() {
        onToggleServer()
    }

    @objc func quitAction() {
        onQuit()
    }

    @objc func openAccessibilitySettingsAction() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - MicSelectionTarget

/// One per microphone submenu item: captures the device UID (nil = system default)
/// so NSMenuItem's single no-argument @objc action can report which item fired.
@MainActor
private final class MicSelectionTarget: NSObject {
    private let uid: String?
    private let onSelect: @MainActor (String?) -> Void

    init(uid: String?, onSelect: @escaping @MainActor (String?) -> Void) {
        self.uid = uid
        self.onSelect = onSelect
    }

    @objc func selectAction() {
        onSelect(uid)
    }
}

// MARK: - StatusBarController

/// Owns the NSStatusItem and keeps the menu up to date.
@MainActor
public final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menuBuilder: StatusMenuBuilder
    private var currentMenu: NSMenu
    // Retains the click bridge so the button's weak target survives.
    private var clickTarget: ButtonClickTarget?

    public init(
        onShowSettings: @escaping @MainActor () -> Void,
        onShowHistory: @escaping @MainActor () -> Void,
        onShowOnboarding: @escaping @MainActor () -> Void,
        onToggleServer: @escaping @MainActor () -> Void,
        onSelectInputDevice: @escaping @MainActor (String?) -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        menuBuilder = StatusMenuBuilder(
            onShowSettings: onShowSettings,
            onShowHistory: onShowHistory,
            onShowOnboarding: onShowOnboarding,
            onToggleServer: onToggleServer,
            onSelectInputDevice: onSelectInputDevice,
            onQuit: onQuit
        )
        // variableLength so the language code fits next to the icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        currentMenu = menuBuilder.buildMenu()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Whisper Native")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }

        // Handle clicks manually (rather than assigning statusItem.menu, which
        // would swallow every click): any click pops the menu.
        let target = ButtonClickTarget { [weak self] in self?.handleClick() }
        clickTarget = target
        if let button = statusItem.button {
            button.target = target
            button.action = #selector(ButtonClickTarget.buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func handleClick() {
        popMenu()
    }

    private func popMenu() {
        guard let button = statusItem.button else { return }
        // Attach the menu just for this display, then detach so the button keeps
        // receiving raw clicks afterward.
        statusItem.menu = currentMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    public func updateMenu(
        serverRunning: Bool,
        modelName: String,
        inputDevices: [AudioInputDevice] = [],
        selectedInputDeviceUID: String? = nil,
        accessibilityWarning: Bool = false,
        downloadingModel: Bool = false,
        whisperEngineActive: Bool = true
    ) {
        currentMenu = menuBuilder.rebuild(
            serverRunning: serverRunning,
            modelName: modelName,
            inputDevices: inputDevices,
            selectedInputDeviceUID: selectedInputDeviceUID,
            accessibilityWarning: accessibilityWarning,
            downloadingModel: downloadingModel,
            whisperEngineActive: whisperEngineActive
        )
    }

    /// Persistent "which language am I dictating in" state, next to the icon.
    /// The dev app appends "·dev" so it stands apart from the installed copy.
    public func updateLanguage(_ language: Language) {
        let devTag = Constants.isDevBuild ? "·dev" : ""
        statusItem.button?.title = " \(language.displayCode)\(devTag)"
        let devPrefix = Constants.isDevBuild ? "WhisperNative Dev, " : ""
        statusItem.button?.toolTip = "\(devPrefix)Transcription language: \(language.displayName)"
    }

    public var button: NSStatusBarButton? { statusItem.button }
}

// MARK: - ButtonClickTarget

// Bridges the status-bar button's @objc action to a @MainActor closure so the
// controller can inspect the triggering event and branch on click type.
@MainActor
private final class ButtonClickTarget: NSObject {
    private let onClick: @MainActor () -> Void

    init(onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
    }

    @objc func buttonClicked() {
        onClick()
    }
}
