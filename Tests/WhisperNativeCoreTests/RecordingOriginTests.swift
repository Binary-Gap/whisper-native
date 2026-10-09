import XCTest
@testable import WhisperNativeCore

final class RecordingOriginTests: XCTestCase {
    func testTurningStartOnVoiceOffCancelsAVoiceStartedRecording() {
        XCTAssertTrue(RecordingOrigin.voice.isCancelled(startOnVoice: false))
    }

    func testVoiceStartedRecordingKeepsGoingWhileTheSettingIsOn() {
        XCTAssertFalse(RecordingOrigin.voice.isCancelled(startOnVoice: true))
    }

    func testHotkeyRecordingIsNeverCancelledByTheSetting() {
        XCTAssertFalse(RecordingOrigin.hotkey.isCancelled(startOnVoice: false))
        XCTAssertFalse(RecordingOrigin.hotkey.isCancelled(startOnVoice: true))
    }
}
