import XCTest
@testable import WhisperNativeCore

final class VoiceProcessingPolicyTests: XCTestCase {
    func testVoiceProcessingIsOnByDefault() {
        XCTAssertTrue(Config().voiceProcessing)
    }

    func testOldConfigWithoutTheKeyDecodesOn() throws {
        let json = #"{"soundFeedback": false}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(config.voiceProcessing)
        XCTAssertFalse(config.soundFeedback)
    }

    func testSettingRoundTrips() throws {
        var config = Config()
        config.voiceProcessing = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(decoded.voiceProcessing)
    }

    func testIdleRecordingOpensTheMicProcessedOnlyWhenOn() {
        XCTAssertEqual(
            VoiceProcessingPolicy.recordingCapture(voiceProcessing: true, isListening: false, includePreRoll: false),
            .open(voiceProcessed: true)
        )
        XCTAssertEqual(
            VoiceProcessingPolicy.recordingCapture(voiceProcessing: false, isListening: false, includePreRoll: false),
            .open(voiceProcessed: false)
        )
    }

    func testVoiceStartedRecordingKeepsTheListeningCapture() {
        for voiceProcessing in [true, false] {
            XCTAssertEqual(
                VoiceProcessingPolicy.recordingCapture(voiceProcessing: voiceProcessing, isListening: true, includePreRoll: true),
                .continueListening
            )
        }
    }

    func testHotkeyDuringListeningReopensProcessedOnlyWhenOn() {
        XCTAssertEqual(
            VoiceProcessingPolicy.recordingCapture(voiceProcessing: true, isListening: true, includePreRoll: false),
            .open(voiceProcessed: true)
        )
        XCTAssertEqual(
            VoiceProcessingPolicy.recordingCapture(voiceProcessing: false, isListening: true, includePreRoll: false),
            .continueListening
        )
    }

    func testStartOnVoiceNoteShowsOnlyWithBothOn() {
        XCTAssertNotNil(VoiceProcessingPolicy.startOnVoiceNote(voiceProcessing: true, startOnVoice: true))
        XCTAssertNil(VoiceProcessingPolicy.startOnVoiceNote(voiceProcessing: true, startOnVoice: false))
        XCTAssertNil(VoiceProcessingPolicy.startOnVoiceNote(voiceProcessing: false, startOnVoice: true))
        XCTAssertNil(VoiceProcessingPolicy.startOnVoiceNote(voiceProcessing: false, startOnVoice: false))
    }
}
