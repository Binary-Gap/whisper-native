import Foundation

/// Where a finished transcript goes, decided from the Output settings and the
/// focus captured at recording start. "Copy to clipboard"
/// (`autoPasteWhenSameApp` off) inserts nothing anywhere, iTerm2 included, so
/// neither auto-submit can fire.
public struct InsertionPlan: Equatable, Sendable {
    /// iTerm2 session to send the text to first; nil skips the bridge.
    public var itermSessionID: String?
    /// Enter after the text in the iTerm2 session.
    public var submitInTerminal: Bool
    /// Cmd+V into the focused app when the bridge is skipped or fails.
    public var pasteIntoFocusedApp: Bool
    /// Return after the Cmd+V paste.
    public var submitAfterPaste: Bool

    public init(itermSessionID: String?, submitInTerminal: Bool, pasteIntoFocusedApp: Bool, submitAfterPaste: Bool) {
        self.itermSessionID = itermSessionID
        self.submitInTerminal = submitInTerminal
        self.pasteIntoFocusedApp = pasteIntoFocusedApp
        self.submitAfterPaste = submitAfterPaste
    }

    /// Why the two auto-submit settings have no effect, nil when they apply.
    /// Settings shows it next to the disabled toggles; the stored values are
    /// kept, so switching back restores them.
    public static func autoSubmitUnavailableReason(autoPasteWhenSameApp: Bool) -> String? {
        autoPasteWhenSameApp ? nil : "Not used with \"Copy to clipboard\": nothing is pasted, so nothing is submitted."
    }

    /// Paste is blocked by a missing Accessibility grant: auto-paste (Cmd+V
    /// and the typing fallback) needs it, "Copy to clipboard" doesn't.
    /// The Output page shows the Accessibility warning while this is true.
    public static func pasteNeedsAccessibility(autoPasteWhenSameApp: Bool, accessibilityGranted: Bool) -> Bool {
        autoPasteWhenSameApp && !accessibilityGranted
    }

    /// Something the user set up can't work until Accessibility is granted:
    /// auto-paste, or a single-key toggle whose event tap couldn't install.
    /// Drives the Hotkeys page warning, its sidebar badge and the status menu
    /// item.
    public static func accessibilityWarningShown(
        autoPasteWhenSameApp: Bool,
        accessibilityGranted: Bool,
        modifierToggleAvailable: Bool
    ) -> Bool {
        !modifierToggleAvailable
            || pasteNeedsAccessibility(autoPasteWhenSameApp: autoPasteWhenSameApp, accessibilityGranted: accessibilityGranted)
    }

    /// `sameApp`: the app focused at recording start is still frontmost.
    /// `autoSubmitSuppressed`: Esc was pressed during the recording.
    public static func make(
        config: Config,
        itermSessionID: String?,
        sameApp: Bool,
        autoSubmitSuppressed: Bool
    ) -> InsertionPlan {
        guard config.autoPasteWhenSameApp else {
            return InsertionPlan(itermSessionID: nil, submitInTerminal: false, pasteIntoFocusedApp: false, submitAfterPaste: false)
        }
        return InsertionPlan(
            itermSessionID: itermSessionID,
            submitInTerminal: itermSessionID != nil && config.autoSubmitInTerminal && !autoSubmitSuppressed,
            pasteIntoFocusedApp: sameApp,
            submitAfterPaste: sameApp && config.autoSubmitInOtherApps && !autoSubmitSuppressed
        )
    }
}
