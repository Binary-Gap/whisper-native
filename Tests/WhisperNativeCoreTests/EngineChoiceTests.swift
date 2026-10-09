import XCTest
@testable import WhisperNativeCore

final class EngineChoiceTests: XCTestCase {

    // MARK: Engine choice

    func testBothGeminiEnginesMapToOneChoice() {
        XCTAssertEqual(EngineChoice(.whisper), .whisper)
        XCTAssertEqual(EngineChoice(.parakeet), .parakeet)
        XCTAssertEqual(EngineChoice(.gemini), .gemini)
        XCTAssertEqual(EngineChoice(.geminiLive), .gemini)
        XCTAssertEqual(EngineChoice.allCases.map(\.name), ["Whisper", "Parakeet", "Gemini"])
    }

    func testLanguageCaptionDescribesEachEngine() {
        XCTAssertTrue(EngineChoice.whisper.languageCaption.contains("language you pick"))
        XCTAssertTrue(EngineChoice.parakeet.languageCaption.contains("alphabet"))
        XCTAssertTrue(EngineChoice(.geminiLive).languageCaption.contains("hint"))
        XCTAssertEqual(EngineChoice(.gemini).languageCaption, EngineChoice(.geminiLive).languageCaption)
    }

    func testGeminiFollowsTheRememberedStreamingChoice() {
        XCTAssertEqual(EngineChoice.gemini.engine(geminiStreaming: true), .geminiLive)
        XCTAssertEqual(EngineChoice.gemini.engine(geminiStreaming: false), .gemini)
        XCTAssertEqual(EngineChoice.whisper.engine(geminiStreaming: true), .whisper)
    }

    func testGeminiIsUnavailableWithoutAKey() {
        XCTAssertNotNil(EngineChoice.gemini.unavailableReason(keyStatus: .missing))
        XCTAssertNil(EngineChoice.gemini.unavailableReason(keyStatus: .keychain))
        XCTAssertNil(EngineChoice.gemini.unavailableReason(keyStatus: .environment))
        XCTAssertNil(EngineChoice.whisper.unavailableReason(keyStatus: .missing))
        XCTAssertNil(EngineChoice.parakeet.unavailableReason(keyStatus: .missing))
        XCTAssertEqual(EngineChoice.gemini.pickerLabel(keyStatus: .keychain), "Gemini")
        XCTAssertNotEqual(EngineChoice.gemini.pickerLabel(keyStatus: .missing), "Gemini")
    }

    func testEngineToSelect() {
        XCTAssertEqual(
            EngineChoice.engineToSelect(.gemini, current: .whisper, geminiStreaming: false, keyStatus: .keychain),
            .gemini
        )
        XCTAssertEqual(
            EngineChoice.engineToSelect(.gemini, current: .parakeet, geminiStreaming: true, keyStatus: .environment),
            .geminiLive
        )
        // No key: Gemini can't be selected.
        XCTAssertNil(EngineChoice.engineToSelect(.gemini, current: .whisper, geminiStreaming: true, keyStatus: .missing))
        // Re-picking Gemini keeps the active Streaming / Batch engine.
        XCTAssertNil(EngineChoice.engineToSelect(.gemini, current: .gemini, geminiStreaming: true, keyStatus: .keychain))
        // Leaving Gemini works without a key.
        XCTAssertEqual(
            EngineChoice.engineToSelect(.whisper, current: .geminiLive, geminiStreaming: true, keyStatus: .missing),
            .whisper
        )
    }

    // MARK: Key status

    func testKeyStatusPrefersKeychainOverEnvironment() {
        XCTAssertEqual(GeminiKeyStatus.resolve(keychainKey: "k", environmentKey: "e"), .keychain)
        XCTAssertEqual(GeminiKeyStatus.resolve(keychainKey: "  ", environmentKey: "e"), .environment)
        XCTAssertEqual(GeminiKeyStatus.resolve(keychainKey: nil, environmentKey: nil), .missing)
        XCTAssertEqual(GeminiKeyStatus.resolve(keychainKey: "", environmentKey: " \n"), .missing)
    }

    func testActiveEngineWarningOnlyForGeminiWithoutKey() {
        XCTAssertNotNil(GeminiKeyStatus.missing.activeEngineWarning(engine: .gemini))
        XCTAssertNotNil(GeminiKeyStatus.missing.activeEngineWarning(engine: .geminiLive))
        XCTAssertNil(GeminiKeyStatus.missing.activeEngineWarning(engine: .whisper))
        XCTAssertNil(GeminiKeyStatus.keychain.activeEngineWarning(engine: .gemini))
        XCTAssertNil(GeminiKeyStatus.environment.activeEngineWarning(engine: .geminiLive))
    }

    // MARK: Key field commit

    func testKeyFieldCommit() {
        XCTAssertEqual(GeminiKeyFieldCommit.resolve(typed: "abc", stored: "abc"), .unchanged)
        XCTAssertEqual(GeminiKeyFieldCommit.resolve(typed: " abc\n", stored: "abc"), .unchanged)
        XCTAssertEqual(GeminiKeyFieldCommit.resolve(typed: " new ", stored: "abc"), .save("new"))
        XCTAssertEqual(GeminiKeyFieldCommit.resolve(typed: "new", stored: nil), .save("new"))
        XCTAssertEqual(GeminiKeyFieldCommit.resolve(typed: "  ", stored: "abc"), .confirmRemoval)
        XCTAssertEqual(GeminiKeyFieldCommit.resolve(typed: "", stored: nil), .unchanged)
    }

    func testRemovalMessageNamesWhatHappensNext() {
        XCTAssertTrue(GeminiKeyFieldCommit.removalMessage(engine: .gemini, hasEnvironmentKey: true).contains("GEMINI_API_KEY"))
        XCTAssertTrue(GeminiKeyFieldCommit.removalMessage(engine: .geminiLive, hasEnvironmentKey: false).contains("stays the active engine"))
        XCTAssertTrue(GeminiKeyFieldCommit.removalMessage(engine: .whisper, hasEnvironmentKey: false).contains("can't be selected"))
    }
}
