import AppKit
import Combine
import CoreGraphics
import KeyboardShortcuts
import WhisperNativeCore

// Manages global hotkey registration for the app target.
// Lone modifier keys (Fn, Option, Command, etc.) are not standard Carbon
// hotkeys, so the user-selected one is captured via a CGEventTap as a
// supplementary toggle binding for toggleDictation.
@MainActor
public final class HotkeyManager: ObservableObject {
    // CGEventTap reference kept alive for Fn capture.
    // nonisolated(unsafe): accessed from deinit which is nonisolated;
    // safe because deinit is the last use and these are only set on the main actor.
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    // Stored callbacks, set during register().
    private var toggleHandler: (@MainActor () -> Void)?
    private var cancelHandler: (@MainActor () -> Void)?
    private var pastLastHandler: (@MainActor () -> Void)?
    private var cycleLanguageHandler: (@MainActor () -> Void)?
    private var toggleStartOnVoiceHandler: (@MainActor () -> Void)?

    // Polls for the Accessibility grant flipping to trusted while it is missing,
    // so the global hotkey self-heals and the paste warnings clear without a relaunch.
    // TCC keys the grant to the running binary's code-signing requirement, so a
    // freshly notarized build always starts ungranted; once the user grants it
    // (or a stale grant is refreshed) this timer installs the tap on the next tick.
    // An LSUIElement menu-bar app doesn't reliably get applicationDidBecomeActive
    // when the user toggles the checkbox in System Settings, so we poll instead of
    // relying on focus notifications alone.
    // nonisolated(unsafe): invalidated from deinit (nonisolated); safe because it's
    // otherwise only touched on the main actor and deinit is the last use.
    nonisolated(unsafe) private var accessibilityPollTimer: Timer?

    // True when the modifier-key toggle is usable: either no modifier key is
    // configured, or one is and the CGEventTap installed successfully. False
    // means a modifier key is set but the tap failed (missing/stale Accessibility
    // grant) — surfaced to the user via the status-bar menu warning.
    @Published public private(set) var modifierToggleAvailable = true

    // Last known Accessibility grant (`AXIsProcessTrusted`). Paste (Cmd+V and the
    // typing fallback) and the modifier tap both need it. Refreshed on every tap
    // (re)install and by the self-heal poll, which runs while it is false.
    @Published public private(set) var accessibilityGranted = AXIsProcessTrusted()

    public init() {}

    deinit {
        // Cannot call MainActor-isolated teardown from deinit on a non-isolated context,
        // so tear down the event tap synchronously here (CFMachPort is not actor-isolated).
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        accessibilityPollTimer?.invalidate()
    }

    /// Register all hotkey handlers. Call once from applicationDidFinishLaunching.
    /// Does not reset user-persisted bindings.
    public func register(
        onToggle: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onPasteLast: @escaping @MainActor () -> Void,
        onCycleLanguage: @escaping @MainActor () -> Void,
        onToggleStartOnVoice: @escaping @MainActor () -> Void
    ) {
        toggleHandler = onToggle
        cancelHandler = onCancel
        pastLastHandler = onPasteLast
        cycleLanguageHandler = onCycleLanguage
        toggleStartOnVoiceHandler = onToggleStartOnVoice

        // Register KeyboardShortcuts handlers (clears previous handler first).
        KeyboardShortcuts.removeHandler(for: .toggleDictation)
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            guard let self else { return }
            self.toggleHandler?()
        }

        KeyboardShortcuts.removeHandler(for: .cancelTranscription)
        KeyboardShortcuts.onKeyDown(for: .cancelTranscription) { [weak self] in
            guard let self else { return }
            self.cancelHandler?()
        }
        // Cancel is only captured while a recording/transcription is active; the
        // Orchestrator toggles this via setCancelHotkeyEnabled so the key (Escape
        // by default) passes through to apps when nothing is in flight.
        KeyboardShortcuts.disable(.cancelTranscription)

        KeyboardShortcuts.removeHandler(for: .pasteLastTranscript)
        KeyboardShortcuts.onKeyDown(for: .pasteLastTranscript) { [weak self] in
            guard let self else { return }
            self.pastLastHandler?()
        }

        KeyboardShortcuts.removeHandler(for: .cycleLanguage)
        KeyboardShortcuts.onKeyDown(for: .cycleLanguage) { [weak self] in
            guard let self else { return }
            self.cycleLanguageHandler?()
        }

        KeyboardShortcuts.removeHandler(for: .toggleStartOnVoice)
        KeyboardShortcuts.onKeyDown(for: .toggleStartOnVoice) { [weak self] in
            guard let self else { return }
            self.toggleStartOnVoiceHandler?()
        }

        installModifierEventTap()
    }

    /// Re-check the modifier-key tap. Call after the user may have changed the
    /// Accessibility grant, so the status-bar warning can clear without a relaunch.
    public func refreshModifierTap() {
        removeModifierEventTap()
        installModifierEventTap()
    }

    /// Re-check availability and, if still not granted, surface the one-shot
    /// system Accessibility prompt (shown only the first time per app). Returns
    /// the availability after the re-check. Callers should open the Accessibility
    /// pane themselves when this returns false, since the prompt fires at most once.
    @discardableResult
    public func requestAccessibilityIfNeeded() -> Bool {
        refreshModifierTap()
        if !modifierToggleAvailable {
            // kAXTrustedCheckOptionPrompt is a non-Sendable global; its literal
            // value is the stable key AppKit expects, so use it directly.
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        return modifierToggleAvailable
    }

    /// Settings' Check Accessibility: re-check the grant and the modifier tap,
    /// and surface the one-shot system prompt when either is missing (paste needs
    /// the grant even with a chord toggle). Returns true when both are fine.
    /// Callers open the Accessibility pane themselves on false.
    @discardableResult
    public func recheckAccessibility() -> Bool {
        refreshModifierTap()
        let ready = accessibilityGranted && modifierToggleAvailable
        if !ready {
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        return ready
    }

    /// Enable/disable the cancel shortcut. While disabled the key is not captured
    /// and passes through to the focused app. The Orchestrator enables it only for
    /// the duration of a recording/transcription.
    public func setCancelHotkeyEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.cancelTranscription)
        } else {
            KeyboardShortcuts.disable(.cancelTranscription)
        }
    }

    /// Unregister all hotkey handlers and disable the Fn event tap.
    public func unregisterAll() {
        KeyboardShortcuts.removeHandler(for: .toggleDictation)
        KeyboardShortcuts.removeHandler(for: .cancelTranscription)
        KeyboardShortcuts.removeHandler(for: .pasteLastTranscript)
        KeyboardShortcuts.removeHandler(for: .cycleLanguage)
        KeyboardShortcuts.removeHandler(for: .toggleStartOnVoice)
        toggleHandler = nil
        cancelHandler = nil
        pastLastHandler = nil
        cycleLanguageHandler = nil
        toggleStartOnVoiceHandler = nil
        stopAccessibilityPoll()
        removeModifierEventTap()
    }

    // MARK: - Modifier-key CGEventTap

    // A lone modifier key (chosen in Settings) acts as a supplementary toggle
    // binding for toggleDictation. We watch flagsChanged events and fire on the
    // key-down edge, when the key's flag bit transitions off → on.
    private func installModifierEventTap() {
        let trusted = AXIsProcessTrusted()
        accessibilityGranted = trusted

        // No modifier key configured: nothing to install. The poll still runs
        // while untrusted, since paste needs the grant too.
        guard SettingsStore.shared.config.toggleModifierKey != .none else {
            modifierToggleAvailable = true
            if trusted { stopAccessibilityPoll() } else { startAccessibilityPoll() }
            return
        }

        // A listen-only session tap can be *created* even without Accessibility —
        // tapCreate returns non-nil but the tap never receives events. So the grant
        // must be checked explicitly; tapCreate success is not proof of permission.
        guard trusted else {
            AppLogger.shared.log(.error, "Modifier-key toggle unavailable — Accessibility permission missing or stale. Grant it in System Settings; the hotkey activates automatically once trusted, no relaunch needed.")
            modifierToggleAvailable = false
            startAccessibilityPoll()
            return
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                manager.handleModifierEvent(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        ) else {
            // Accessibility is trusted but the tap still couldn't be created (rare —
            // resource exhaustion or a transient CoreGraphics failure).
            AppLogger.shared.log(.error, "Modifier-key event tap creation failed despite Accessibility being granted. Single-key toggle disabled.")
            modifierToggleAvailable = false
            Unmanaged<HotkeyManager>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        modifierToggleAvailable = true
        stopAccessibilityPoll()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Accessibility self-heal poll

    /// Poll for the Accessibility grant so the global hotkey comes up on its own
    /// the moment trust is granted, surviving the notarize churn that resets TCC.
    /// Fires availability changes through onAvailabilityChanged so the UI (status
    /// menu warning) refreshes without a relaunch.
    public var onAvailabilityChanged: (@MainActor () -> Void)?

    private func startAccessibilityPoll() {
        guard accessibilityPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                // Trust flipped to granted: (re)install the tap. installModifierEventTap
                // records the grant, stops this poll on success and flips
                // modifierToggleAvailable true.
                self.removeModifierEventTap()
                self.installModifierEventTap()
                if self.modifierToggleAvailable {
                    AppLogger.shared.log(.info, "Accessibility granted — paste and modifier-key toggle available without relaunch.")
                    self.onAvailabilityChanged?()
                }
            }
        }
        // Run in common modes so it keeps ticking during menu tracking / modal loops.
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPollTimer = timer
    }

    private func stopAccessibilityPoll() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    private func removeModifierEventTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    // Tracks the configured key's previous flag state to detect the key-down edge.
    private var modifierWasDown = false

    private func handleModifierEvent(_ event: CGEvent) {
        // Read the setting live so a Settings change takes effect instantly.
        let key = SettingsStore.shared.config.toggleModifierKey
        guard key != .none else {
            modifierWasDown = false
            return
        }

        let isDown = event.flags.rawValue & key.flagMask != 0
        defer { modifierWasDown = isDown }
        // Fire only on the key-down edge.
        guard isDown && !modifierWasDown else { return }

        // Left/right modifiers share a flag bit, so disambiguate by keycode.
        // Fn has no distinct keycode; its flag bit alone identifies it.
        if let expectedKeyCode = key.keyCode {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == expectedKeyCode else { return }
        }

        DispatchQueue.main.async { [weak self] in
            self?.toggleHandler?()
        }
    }
}
