import XCTest
@testable import WhisperNativeCore

final class GlobeKeyActionTests: XCTestCase {
    func testPreferenceValuesMapToActions() {
        XCTAssertEqual(GlobeKeyAction(preferenceValue: 0), .doNothing)
        XCTAssertEqual(GlobeKeyAction(preferenceValue: 1), .changeInputSource)
        XCTAssertEqual(GlobeKeyAction(preferenceValue: 2), .showEmoji)
        XCTAssertEqual(GlobeKeyAction(preferenceValue: 3), .startDictation)
        XCTAssertEqual(GlobeKeyAction(preferenceValue: nil), .other)
        XCTAssertEqual(GlobeKeyAction(preferenceValue: 9), .other)
    }

    func testNoWarningWhenGlobeKeyDoesNothing() {
        XCTAssertNil(GlobeKeyAction.doNothing.fnConflictWarning)
    }

    func testWarningNamesTheCurrentAction() {
        let warning = GlobeKeyAction.showEmoji.fnConflictWarning
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("“Show Emoji & Symbols”"))
        XCTAssertTrue(warning!.contains("“Do Nothing”"))
    }

    func testWarningWithoutAKnownAction() {
        let warning = GlobeKeyAction.other.fnConflictWarning
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.hasPrefix("The Globe key has an action"))
    }
}
