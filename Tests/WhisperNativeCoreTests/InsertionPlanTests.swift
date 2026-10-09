import XCTest
@testable import WhisperNativeCore

final class InsertionPlanTests: XCTestCase {
    private func config(autoPaste: Bool, submitInTerminal: Bool = true, submitInOtherApps: Bool = true) -> Config {
        var config = Config()
        config.autoPasteWhenSameApp = autoPaste
        config.autoSubmitInTerminal = submitInTerminal
        config.autoSubmitInOtherApps = submitInOtherApps
        return config
    }

    private let clipboardOnly = InsertionPlan(itermSessionID: nil, submitInTerminal: false, pasteIntoFocusedApp: false, submitAfterPaste: false)

    func testClipboardOnlySkipsItermSessionAndSubmit() {
        let plan = InsertionPlan.make(config: config(autoPaste: false), itermSessionID: "w0t0p0", sameApp: true, autoSubmitSuppressed: false)
        XCTAssertEqual(plan, clipboardOnly)
    }

    func testClipboardOnlySkipsPasteInOtherApps() {
        let plan = InsertionPlan.make(config: config(autoPaste: false), itermSessionID: nil, sameApp: true, autoSubmitSuppressed: false)
        XCTAssertEqual(plan, clipboardOnly)
    }

    func testAutoPasteSendsToItermSessionWithSubmit() {
        let plan = InsertionPlan.make(config: config(autoPaste: true), itermSessionID: "w0t0p0", sameApp: false, autoSubmitSuppressed: false)
        XCTAssertEqual(plan.itermSessionID, "w0t0p0")
        XCTAssertTrue(plan.submitInTerminal)
        XCTAssertFalse(plan.pasteIntoFocusedApp)
    }

    func testAutoPasteKeepsCmdVFallbackWhenStillFocused() {
        let plan = InsertionPlan.make(config: config(autoPaste: true), itermSessionID: "w0t0p0", sameApp: true, autoSubmitSuppressed: false)
        XCTAssertTrue(plan.pasteIntoFocusedApp)
        XCTAssertTrue(plan.submitAfterPaste)
    }

    func testFocusChangeFallsBackToClipboard() {
        let plan = InsertionPlan.make(config: config(autoPaste: true), itermSessionID: nil, sameApp: false, autoSubmitSuppressed: false)
        XCTAssertEqual(plan, clipboardOnly)
    }

    func testEscSuppressesBothSubmits() {
        let plan = InsertionPlan.make(config: config(autoPaste: true), itermSessionID: "w0t0p0", sameApp: true, autoSubmitSuppressed: true)
        XCTAssertEqual(plan.itermSessionID, "w0t0p0")
        XCTAssertFalse(plan.submitInTerminal)
        XCTAssertTrue(plan.pasteIntoFocusedApp)
        XCTAssertFalse(plan.submitAfterPaste)
    }

    func testSubmitSettingsOff() {
        let plan = InsertionPlan.make(
            config: config(autoPaste: true, submitInTerminal: false, submitInOtherApps: false),
            itermSessionID: "w0t0p0", sameApp: true, autoSubmitSuppressed: false
        )
        XCTAssertFalse(plan.submitInTerminal)
        XCTAssertFalse(plan.submitAfterPaste)
    }

    func testPasteNeedsAccessibilityOnlyWhileAutoPasting() {
        XCTAssertTrue(InsertionPlan.pasteNeedsAccessibility(autoPasteWhenSameApp: true, accessibilityGranted: false))
        XCTAssertFalse(InsertionPlan.pasteNeedsAccessibility(autoPasteWhenSameApp: true, accessibilityGranted: true))
        XCTAssertFalse(InsertionPlan.pasteNeedsAccessibility(autoPasteWhenSameApp: false, accessibilityGranted: false))
    }

    func testAccessibilityWarningCoversPasteAndSingleKeyToggle() {
        // Chord toggle, auto-paste, no grant: paste is what breaks.
        XCTAssertTrue(InsertionPlan.accessibilityWarningShown(autoPasteWhenSameApp: true, accessibilityGranted: false, modifierToggleAvailable: true))
        // Clipboard only, single-key toggle without its tap.
        XCTAssertTrue(InsertionPlan.accessibilityWarningShown(autoPasteWhenSameApp: false, accessibilityGranted: false, modifierToggleAvailable: false))
        // Clipboard only with a chord toggle needs no grant.
        XCTAssertFalse(InsertionPlan.accessibilityWarningShown(autoPasteWhenSameApp: false, accessibilityGranted: false, modifierToggleAvailable: true))
        XCTAssertFalse(InsertionPlan.accessibilityWarningShown(autoPasteWhenSameApp: true, accessibilityGranted: true, modifierToggleAvailable: true))
    }
}
