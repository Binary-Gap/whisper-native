import XCTest
@testable import WhisperNativeCore

final class LanguageTests: XCTestCase {

    private func decode(_ code: String) throws -> Language {
        try JSONDecoder().decode(Language.self, from: Data("\"\(code)\"".utf8))
    }

    func testPersistedCodesDecodeUnchanged() throws {
        XCTAssertEqual(try decode("en"), .english)
        XCTAssertEqual(try decode("pt"), .portuguese)
        XCTAssertEqual(try decode("auto"), .auto)
        XCTAssertEqual(try decode("yue").rawValue, "yue")
    }

    func testUnknownCodeDecodesToAuto() throws {
        XCTAssertEqual(try decode("xx"), .auto)
    }

    func testEncodesAsBareCode() throws {
        let data = try JSONEncoder().encode([Language.portuguese, .auto])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["pt","auto"]"#)
    }

    func testAllListsAutoFirstAndEveryWhisperCode() {
        XCTAssertEqual(Language.all.first, .auto)
        XCTAssertEqual(Language.all.count, Language.whisperCodes.count + 1)
        XCTAssertEqual(Set(Language.all).count, Language.all.count)
    }

    func testDisplayCode() {
        XCTAssertEqual(Language.auto.displayCode, "AUTO")
        XCTAssertEqual(Language.portuguese.displayCode, "PT")
    }

    func testCycleAdvancesAndWraps() {
        let cycle: [Language] = [.portuguese, .english, .auto]
        XCTAssertEqual(Language.next(after: .portuguese, in: cycle), .english)
        XCTAssertEqual(Language.next(after: .english, in: cycle), .auto)
        XCTAssertEqual(Language.next(after: .auto, in: cycle), .portuguese)
    }

    func testCycleFromLanguageOutsideSubsetStartsAtFirstEntry() throws {
        let german = try XCTUnwrap(Language(rawValue: "de"))
        XCTAssertEqual(Language.next(after: german, in: [.english, .auto]), .english)
    }

    func testEmptyCycleKeepsCurrent() {
        XCTAssertEqual(Language.next(after: .english, in: []), .english)
    }

    func testDefaultCycleIsAutoPlusSupportedSystemLanguage() {
        XCTAssertEqual(Config.defaultActiveLanguages(systemLanguage: .portuguese), [.auto, .portuguese])
        XCTAssertEqual(Config.defaultActiveLanguages(systemLanguage: nil), [.auto])
        XCTAssertEqual(Language.systemLanguage(code: "nb")?.rawValue, "no")
        XCTAssertNil(Language.systemLanguage(code: "xx"))
    }

    func testConfigWithoutCycleFieldDecodesWithDefault() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"selectedLanguage":"pt"}"#.utf8))
        XCTAssertEqual(config.selectedLanguage, .portuguese)
        XCTAssertEqual(config.activeLanguages, ActiveLanguages.normalized(Config.defaultActiveLanguages(), selected: .portuguese))
    }

    func testCycleRoundTripsThroughConfig() throws {
        var config = Config()
        config.activeLanguages = [.portuguese, .english, .auto]
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.activeLanguages, [.portuguese, .english, .auto])
    }

    func testCycleWithUnknownCodeDecodesWithoutDuplicateAuto() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"cycleLanguages":["xx","pt","auto"]}"#.utf8))
        XCTAssertEqual(config.activeLanguages, [.auto, .portuguese])
    }

    func testLatinScriptDetection() {
        XCTAssertTrue(Language.isLatinScript(code: "pt"))
        XCTAssertTrue(Language.isLatinScript(code: "en"))
        XCTAssertFalse(Language.isLatinScript(code: "ru"))
        XCTAssertFalse(Language.isLatinScript(code: "ja"))
    }

    /// Stand-in for FluidAudio's script-filter enum (not importable from tests).
    private enum ScriptHint: String {
        case portuguese = "pt"
        case russian = "ru"
    }

    func testParakeetHintFollowsSupportedSelection() throws {
        let russian = try XCTUnwrap(Language(rawValue: "ru"))
        let hint: ScriptHint? = ParakeetBackend.tokenFilterLanguage(for: russian, systemLanguageCode: "en")
        XCTAssertEqual(hint, .russian)
    }

    func testParakeetHintForAutoDependsOnSystemScript() {
        let latinHint: ScriptHint? = ParakeetBackend.tokenFilterLanguage(for: .auto, systemLanguageCode: "en")
        XCTAssertEqual(latinHint, .portuguese)
        let noHint: ScriptHint? = ParakeetBackend.tokenFilterLanguage(for: .auto, systemLanguageCode: "ja")
        XCTAssertNil(noHint)
    }

    func testParakeetHintForUnsupportedSelectionUsesItsOwnScript() throws {
        let japanese = try XCTUnwrap(Language(rawValue: "ja"))
        let japaneseHint: ScriptHint? = ParakeetBackend.tokenFilterLanguage(for: japanese, systemLanguageCode: "en")
        XCTAssertNil(japaneseHint)
        let turkish = try XCTUnwrap(Language(rawValue: "tr"))
        let turkishHint: ScriptHint? = ParakeetBackend.tokenFilterLanguage(for: turkish, systemLanguageCode: "ja")
        XCTAssertEqual(turkishHint, .portuguese)
    }
}
