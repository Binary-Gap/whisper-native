@preconcurrency import AppKit
import CoreGraphics

// Bridge for kAXTrustedCheckOptionPrompt which is a non-Sendable ObjC global.
// @preconcurrency import suppresses the Sendable warning from AppKit globals.
private nonisolated func _requestAccessibilityPermissionImpl() {
    let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
    AXIsProcessTrustedWithOptions(opts)
}

// MARK: - Protocol

@MainActor
public protocol TextInserting: AnyObject {
    /// Saves clipboard, sets text, sends Cmd+V, restores clipboard after 0.5s.
    /// Throws `AppError.accessibilityDenied` when the process is not trusted,
    /// leaving the text on the clipboard.
    func insertText(_ text: String) async throws
    /// Wraps text in <audio>\n...\n</audio> then calls insertText.
    func insertTextWithAudioTags(_ text: String) async throws
    /// Copies text to clipboard only — no paste.
    func copyToClipboard(_ text: String)
}

// MARK: - Implementation

@MainActor
public final class TextInserter: TextInserting {

    private let cmdVDelay: TimeInterval = 0.15
    private let clipboardRestoreDelay: TimeInterval = 0.5
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    public init() {}

    public func insertText(_ text: String) async throws {
        let pasteboard = NSPasteboard.general

        // Posting to .cghidEventTap requires Accessibility trust. Without it the
        // events are dropped silently and the paste never lands, so fail loudly
        // and leave the transcript on the clipboard for a manual paste.
        guard Self.hasAccessibilityPermission() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            AppLogger.shared.log(
                .error,
                "insertText: Accessibility permission denied — Cmd+V dropped. "
                    + "\(text.count) chars left on the clipboard."
            )
            throw AppError.accessibilityDenied
        }

        // Snapshot current clipboard contents.
        let savedChangeCount = pasteboard.changeCount
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        // Write new text.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small settle delay before synthesising the keystroke so slow apps catch up.
        try await Task.sleep(nanoseconds: UInt64(cmdVDelay * 1_000_000_000))

        // Synthesise Cmd+V via CGEvent to the frontmost application.
        postCmdV()

        // Restore original clipboard after the paste completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            // Only restore if nothing else has written to the clipboard in the
            // interim (change count unchanged means our write is still there).
            if NSPasteboard.general.changeCount == savedChangeCount + 1 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(savedItems)
            }
        }

        AppLogger.shared.log(.info, "insertText: pasted \(text.count) chars via Cmd+V")
    }

    public func insertTextWithAudioTags(_ text: String) async throws {
        try await insertText(Constants.wrapWithAudioTags(text))
    }

    public func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppLogger.shared.log(.info, "copyToClipboard: \(text.count) chars")
    }

    // MARK: - Secondary path: unicode char-by-char typing via CGEvent

    /// Fallback for apps that cannot receive a paste event. Types each Unicode
    /// scalar individually using CGEvent key-down / key-up pairs.
    public func typeTextCharByChar(_ text: String) throws {
        guard Self.hasAccessibilityPermission() else {
            AppLogger.shared.log(
                .error,
                "typeTextCharByChar: Accessibility permission denied — keystrokes dropped."
            )
            throw AppError.accessibilityDenied
        }

        for scalar in text.unicodeScalars {
            guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let keyUp   = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            else {
                throw AppError.textInsertionFailed("CGEvent creation failed for scalar \(scalar)")
            }
            var utf16: [UniChar] = Array(String(scalar).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        AppLogger.shared.log(.debug, "typeTextCharByChar: typed \(text.count) scalars")
    }

    // MARK: - Accessibility helpers

    /// Returns true when the process has Accessibility permission, which every
    /// CGEvent post to `.cghidEventTap` requires — both the Cmd+V paste and the
    /// char-by-char typing fallback.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility access in System Settings.
    /// Shows the standard system dialog; does NOT block.
    public static func requestAccessibilityPermission() {
        _requestAccessibilityPermissionImpl()
        AppLogger.shared.log(.info, "Accessibility permission prompt displayed")
    }

    // MARK: - Private

    private func postCmdV() {
        // Key code 9 = 'v' on US layout (invariant across layouts for CGEvent).
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: false)
        else {
            AppLogger.shared.log(.error, "Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
