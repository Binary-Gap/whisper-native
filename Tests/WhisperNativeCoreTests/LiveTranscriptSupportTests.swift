import XCTest
@testable import WhisperNativeCore

final class LiveTranscriptSupportTests: XCTestCase {
    func testOnlyParakeetAndGeminiLiveHaveALiveTranscript() {
        for engine in TranscriptionEngine.allCases {
            let expected = engine == .parakeet || engine == .geminiLive
            XCTAssertEqual(engine.hasLiveTranscript, expected, "\(engine)")
        }
    }

    func testStopWordUnavailableOnlyWithoutLiveTranscript() {
        XCTAssertNil(TranscriptionEngine.parakeet.stopWordUnavailableReason)
        XCTAssertNil(TranscriptionEngine.geminiLive.stopWordUnavailableReason)
        XCTAssertNotNil(TranscriptionEngine.whisper.stopWordUnavailableReason)
        XCTAssertNotNil(TranscriptionEngine.gemini.stopWordUnavailableReason)
    }

    func testReasonNamesTheSupportedEngines() throws {
        let reason = try XCTUnwrap(TranscriptionEngine.whisper.stopWordUnavailableReason)
        XCTAssertTrue(reason.contains("Parakeet"))
        XCTAssertTrue(reason.contains("Gemini Live"))
        XCTAssertTrue(reason.contains("Whisper"))
    }

    func testAutoSubmitUnavailableOnlyInClipboardMode() {
        XCTAssertNil(InsertionPlan.autoSubmitUnavailableReason(autoPasteWhenSameApp: true))
        XCTAssertNotNil(InsertionPlan.autoSubmitUnavailableReason(autoPasteWhenSameApp: false))
    }
}
