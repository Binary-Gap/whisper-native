import XCTest
@testable import WhisperNativeCore

final class LineWrapperTests: XCTestCase {

    func testBreaksBetweenWordsAtOrBelowWidth() {
        XCTAssertEqual(
            LineWrapper.wrap("one two three four five six", width: 10),
            "one two\nthree four\nfive six"
        )
    }

    func testKeepsExistingLineBreaksAndOverlongWords() {
        XCTAssertEqual(
            LineWrapper.wrap("First sentence here.\nSupercalifragilistic word", width: 12),
            "First\nsentence\nhere.\nSupercalifragilistic\nword"
        )
    }
}
