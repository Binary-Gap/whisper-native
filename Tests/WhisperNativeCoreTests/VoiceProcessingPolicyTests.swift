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

    func testTurningVoiceProcessingOnTurnsStartOnVoiceOff() {
        let previous = Config(voiceProcessing: false, startOnVoice: true)
        let current = Config(voiceProcessing: true, startOnVoice: true)
        let resolved = VoiceProcessingPolicy.resolveExclusive(previous: previous, current: current)
        XCTAssertTrue(resolved.config.voiceProcessing)
        XCTAssertFalse(resolved.config.startOnVoice)
        XCTAssertEqual(resolved.turnedOff, .startOnVoice)
    }

    func testTurningStartOnVoiceOnTurnsVoiceProcessingOff() {
        let previous = Config(voiceProcessing: true, startOnVoice: false)
        let current = Config(voiceProcessing: true, startOnVoice: true)
        let resolved = VoiceProcessingPolicy.resolveExclusive(previous: previous, current: current)
        XCTAssertFalse(resolved.config.voiceProcessing)
        XCTAssertTrue(resolved.config.startOnVoice)
        XCTAssertEqual(resolved.turnedOff, .voiceProcessing)
    }

    func testOlderConfigWithBothOnKeepsStartOnVoice() {
        let both = Config(voiceProcessing: true, startOnVoice: true)
        let resolved = VoiceProcessingPolicy.resolveExclusive(previous: both, current: both)
        XCTAssertFalse(resolved.config.voiceProcessing)
        XCTAssertTrue(resolved.config.startOnVoice)
    }

    func testAtMostOneOnIsLeftAlone() {
        for (voiceProcessing, startOnVoice) in [(true, false), (false, true), (false, false)] {
            let current = Config(voiceProcessing: voiceProcessing, startOnVoice: startOnVoice)
            let resolved = VoiceProcessingPolicy.resolveExclusive(previous: Config(voiceProcessing: true, startOnVoice: true), current: current)
            XCTAssertEqual(resolved.config.voiceProcessing, voiceProcessing)
            XCTAssertEqual(resolved.config.startOnVoice, startOnVoice)
            XCTAssertNil(resolved.turnedOff)
        }
    }
}
