import Foundation

/// Where a finished transcript goes, decided from the Output settings and the
/// focus captured at recording start. "Copy to clipboard"
/// (`autoPasteWhenSameApp` off) inserts nothing anywhere, iTerm2 and Buildpick
/// included, so no auto-submit can fire.
public struct InsertionPlan: Equatable, Sendable {
    /// iTerm2 session to send the text to first; nil skips the bridge.
    public var itermSessionID: String?
    /// Enter after the text in the iTerm2 session.
    public var submitInTerminal: Bool
    /// Buildpick session to send the text to first; nil skips the bridge.
    public var buildpickSessionID: String?
    /// Send the text as a prompt in the Buildpick session; false leaves it
    /// unsent in that session's compose box.
    public var submitInBuildpick: Bool
    /// Cmd+V into the focused app when the bridges are skipped or fail.
    public var pasteIntoFocusedApp: Bool
    /// Return after the Cmd+V paste.
    public var submitAfterPaste: Bool

    public init(
        itermSessionID: String?,
        submitInTerminal: Bool,
        buildpickSessionID: String? = nil,
        submitInBuildpick: Bool = false,
        pasteIntoFocusedApp: Bool,
        submitAfterPaste: Bool
    ) {
        self.itermSessionID = itermSessionID
        self.submitInTerminal = submitInTerminal
        self.buildpickSessionID = buildpickSessionID
        self.submitInBuildpick = submitInBuildpick
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
    /// `buildpickSessionID`: the Buildpick session focused at recording start;
    /// it follows the "other apps" auto-submit setting.
    /// `autoSubmitSuppressed`: Esc was pressed during the recording.
    public static func make(
        config: Config,
        itermSessionID: String?,
        buildpickSessionID: String? = nil,
        sameApp: Bool,
        autoSubmitSuppressed: Bool
    ) -> InsertionPlan {
        guard config.autoPasteWhenSameApp else {
            return InsertionPlan(itermSessionID: nil, submitInTerminal: false, pasteIntoFocusedApp: false, submitAfterPaste: false)
        }
        return InsertionPlan(
            itermSessionID: itermSessionID,
            submitInTerminal: itermSessionID != nil && config.autoSubmitInTerminal && !autoSubmitSuppressed,
            buildpickSessionID: buildpickSessionID,
            submitInBuildpick: buildpickSessionID != nil && config.autoSubmitInOtherApps && !autoSubmitSuppressed,
            pasteIntoFocusedApp: sameApp,
            submitAfterPaste: sameApp && config.autoSubmitInOtherApps && !autoSubmitSuppressed
        )
    }
}
