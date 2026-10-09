import XCTest
@testable import WhisperNativeCore

final class WhisperServerDisplayTests: XCTestCase {

    // MARK: Status

    func testStoppedIsAProblemOnlyWhileWhisperIsActive() {
        XCTAssertEqual(
            WhisperServerDisplay.resolve(health: .stopped, isWhisperActive: true),
            WhisperServerDisplay(label: "Stopped", tone: .problem)
        )
        XCTAssertEqual(
            WhisperServerDisplay.resolve(health: .stopped, isWhisperActive: false),
            WhisperServerDisplay(label: "Not running, Whisper isn't the active engine", tone: .neutral)
        )
    }

    func testRunningAndCheckingIgnoreTheActiveEngine() {
        for active in [true, false] {
            XCTAssertEqual(WhisperServerDisplay.resolve(health: .running, isWhisperActive: active).tone, .good)
            XCTAssertEqual(WhisperServerDisplay.resolve(health: .checking, isWhisperActive: active).tone, .pending)
        }
    }

    func testToggleInFlightWinsOverHealth() {
        XCTAssertEqual(
            WhisperServerDisplay.resolve(health: .stopped, isWhisperActive: true, toggle: .starting),
            WhisperServerDisplay(label: "Starting…", tone: .pending)
        )
        XCTAssertEqual(
            WhisperServerDisplay.resolve(health: .running, isWhisperActive: true, toggle: .stopping).label,
            "Stopping…"
        )
    }

    // MARK: Start/Stop

    func testToggleEnabledOnlyWhenActiveAndIdle() {
        XCTAssertNil(WhisperServerDisplay.toggleBlockedReason(isWhisperActive: true, isDownloading: false, health: .stopped, isToggling: false))
        XCTAssertNil(WhisperServerDisplay.toggleBlockedReason(isWhisperActive: true, isDownloading: false, health: .running, isToggling: false))
    }

    func testToggleBlockedReasonsNameTheFix() {
        XCTAssertEqual(
            WhisperServerDisplay.toggleBlockedReason(isWhisperActive: false, isDownloading: true, health: .stopped, isToggling: false),
            "Use Whisper first: the server runs only while Whisper is the active engine."
        )
        XCTAssertEqual(
            WhisperServerDisplay.toggleBlockedReason(isWhisperActive: true, isDownloading: true, health: .stopped, isToggling: false),
            "Wait for the model download to finish."
        )
        XCTAssertNotNil(WhisperServerDisplay.toggleBlockedReason(isWhisperActive: true, isDownloading: false, health: .stopped, isToggling: true))
        XCTAssertNotNil(WhisperServerDisplay.toggleBlockedReason(isWhisperActive: true, isDownloading: false, health: .checking, isToggling: false))
    }

    // MARK: Model preparation

    func testPreparationPlan() {
        XCTAssertEqual(WhisperModelPreparation.plan(modelReadable: true, vadReadable: true), .ready)
        XCTAssertEqual(WhisperModelPreparation.plan(modelReadable: true, vadReadable: false), .downloadVadOnly)
        XCTAssertEqual(WhisperModelPreparation.plan(modelReadable: false, vadReadable: true), .askToDownloadModel)
        XCTAssertEqual(WhisperModelPreparation.plan(modelReadable: false, vadReadable: false), .askToDownloadModel)
    }
}
