import XCTest
@testable import WhisperNativeCore

final class RecordingTimeoutFormatTests: XCTestCase {
    func testLabelFormatsSecondsAndMinutes() {
        XCTAssertEqual(RecordingTimeoutFormat.label(seconds: 10), "10 s")
        XCTAssertEqual(RecordingTimeoutFormat.label(seconds: 60), "1 min")
        XCTAssertEqual(RecordingTimeoutFormat.label(seconds: 90), "1 min 30 s")
        XCTAssertEqual(RecordingTimeoutFormat.label(seconds: 120), "2 min")
        XCTAssertEqual(RecordingTimeoutFormat.label(seconds: 600), "10 min")
    }

    func testWarningOnlyForGeminiBatchAboveLimit() {
        XCTAssertNil(RecordingTimeoutFormat.geminiBatchWarning(seconds: 420, engine: .gemini))
        XCTAssertNotNil(RecordingTimeoutFormat.geminiBatchWarning(seconds: 430, engine: .gemini))
        XCTAssertNil(RecordingTimeoutFormat.geminiBatchWarning(seconds: 600, engine: .whisper))
        XCTAssertNil(RecordingTimeoutFormat.geminiBatchWarning(seconds: 600, engine: .parakeet))
        XCTAssertNil(RecordingTimeoutFormat.geminiBatchWarning(seconds: 600, engine: .geminiLive))
    }
}
