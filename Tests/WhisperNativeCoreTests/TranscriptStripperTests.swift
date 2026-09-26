import XCTest
@testable import WhisperNativeCore

final class TranscriptStripperTests: XCTestCase {

    private let anchor = "end of calibration sample"

    func testStripsUpToAndIncludingAnchor() {
        let combined = "I opened the website and backed everything up. End of calibration sample. Now here is the real dictation."
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, "Now here is the real dictation.")
    }

    func testMatchesAnchorDespiteCasePunctuationSpacingDrift() {
        // Whisper may re-punctuate/re-case the anchor between runs.
        let combined = "blah blah End-of-Calibration, Sample! now the real message"
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, "now the real message")
    }

    func testReturnsUnchangedWhenAnchorMissing() {
        // Never guess: leaking calibration text beats truncating real dictation.
        let combined = "Something completely unrelated was transcribed."
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, combined)
    }

    func testEmptyAnchorReturnsTranscriptUnchanged() {
        let combined = "Real dictation only."
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: "")
        XCTAssertEqual(result, combined)
    }

    func testAnchorAtVeryEndReturnsEmpty() {
        let combined = "The calibration sentence. End of calibration sample."
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, "")
    }

    func testMatchesAnchorDespiteOneCharMisTranscription() {
        // Real-world failure: whisper drops the hard 'd', "End of" -> "and of",
        // so "andofcalibrationsample" must still match "endofcalibrationsample".
        let combined = "some priming words and of calibration sample now the real dictation"
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, "now the real dictation")
    }

    func testMatchesAnchorWithDroppedCharacter() {
        // Deletion: "calibraton" (missing 'i') should still align via edit distance.
        let combined = "priming end of calibraton sample real message here"
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, "real message here")
    }

    func testDoesNotFuzzyMatchUnrelatedText() {
        // Well below threshold: must not truncate real dictation.
        let combined = "The quick brown fox jumps over the lazy sleeping dog today."
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, combined)
    }

    func testStripsOnlyFirstAnchorOccurrence() {
        // If the phrase somehow recurs in real dictation, cut on the first (the
        // calibration one) and keep the rest verbatim.
        let combined = "priming text end of calibration sample and then user says end of calibration sample again"
        let result = TranscriptStripper.stripCalibrationPrefix(from: combined, anchorPhrase: anchor)
        XCTAssertEqual(result, "and then user says end of calibration sample again")
    }
}
