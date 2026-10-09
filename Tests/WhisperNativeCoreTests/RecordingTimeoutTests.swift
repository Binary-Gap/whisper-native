import XCTest
@testable import WhisperNativeCore

final class RecordingTimeoutTests: XCTestCase {
    func testDefaultTimeoutIsFiveMinutes() {
        XCTAssertEqual(Config().recordingTimeoutSeconds, 300)
        XCTAssertEqual(Constants.defaultRecordingTimeoutSeconds, 300)
    }

    func testConfiguredTimeoutRoundTrips() throws {
        var config = Config()
        config.recordingTimeoutSeconds = 120
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.recordingTimeoutSeconds, 120)
    }

    func testWatchdogUsesConfiguredValueInsideRange() {
        XCTAssertEqual(AudioRecorder.watchdogSeconds(forConfigured: 10), 10)
        XCTAssertEqual(AudioRecorder.watchdogSeconds(forConfigured: 120), 120)
        XCTAssertEqual(AudioRecorder.watchdogSeconds(forConfigured: 600), 600)
    }

    func testWatchdogClampsOutOfRangeValues() {
        XCTAssertEqual(AudioRecorder.watchdogSeconds(forConfigured: 0), 10)
        XCTAssertEqual(AudioRecorder.watchdogSeconds(forConfigured: -5), 10)
        XCTAssertEqual(AudioRecorder.watchdogSeconds(forConfigured: 5000), 600)
    }

    // Configs saved before normalizeAudio/noiseReduction were removed still
    // decode, keeping the user's other settings.
    func testConfigWithRemovedAudioKeysStillDecodes() throws {
        let json = #"{"normalizeAudio": false, "noiseReduction": 10, "recordingTimeoutSeconds": 90, "soundFeedback": false}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.recordingTimeoutSeconds, 90)
        XCTAssertFalse(config.soundFeedback)
    }

    func testEncodedConfigOmitsRemovedAudioKeys() throws {
        let data = try JSONEncoder().encode(Config())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["normalizeAudio"])
        XCTAssertNil(object["noiseReduction"])
        XCTAssertNotNil(object["recordingTimeoutSeconds"])
    }
}
