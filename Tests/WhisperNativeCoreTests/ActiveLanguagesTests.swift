import XCTest
@testable import WhisperNativeCore

final class ActiveLanguagesTests: XCTestCase {

    private func language(_ code: String) throws -> Language {
        try XCTUnwrap(Language(rawValue: code))
    }

    // Fixed names so the tests don't depend on the machine's locale.
    private let names = [
        "auto": "Auto detect", "en": "English", "pt": "Português", "de": "German",
        "es": "Spanish", "et": "Estonian", "fr": "French",
    ]

    private func addable(_ query: String, active: [Language]) throws -> [String] {
        let all = try ["auto", "en", "pt", "de", "es", "et", "fr"].map(language)
        return ActiveLanguages.addable(matching: query, active: active, all: all) { self.names[$0.rawValue] ?? $0.rawValue }
            .map(\.rawValue)
    }

    func testBlankQueryMatchesNothing() throws {
        XCTAssertEqual(try addable("", active: []), [])
        XCTAssertEqual(try addable("   ", active: []), [])
    }

    func testMatchesNameCaseAndDiacriticInsensitive() throws {
        XCTAssertEqual(try addable("PORTUGUES", active: []), ["pt"])
        XCTAssertEqual(try addable("guê", active: []), ["pt"])
    }

    func testExactCodeFirstThenPrefixThenContains() throws {
        // "es": exact code Spanish, then Estonian (code/name prefix), then
        // Português ("Portugues" contains "es").
        XCTAssertEqual(try addable("es", active: []), ["es", "et", "pt"])
    }

    func testActiveLanguagesAreExcluded() throws {
        XCTAssertEqual(try addable("es", active: [try language("es"), .portuguese]), ["et"])
    }

    func testDefaultNamesFindLanguagesByCode() {
        XCTAssertEqual(ActiveLanguages.addable(matching: "pt", active: [.auto]).first, .portuguese)
        XCTAssertFalse(ActiveLanguages.addable(matching: "pt", active: [.portuguese]).contains(.portuguese))
    }

    func testAddingAppendsOnce() {
        XCTAssertEqual(ActiveLanguages.adding(.english, to: [.auto]), [.auto, .english])
        XCTAssertEqual(ActiveLanguages.adding(.auto, to: [.auto, .english]), [.auto, .english])
    }

    func testRemovingKeepsSelectionWhenItStaysActive() {
        let result = ActiveLanguages.removing(.english, from: [.auto, .english, .portuguese], selected: .portuguese)
        XCTAssertEqual(result.active, [.auto, .portuguese])
        XCTAssertEqual(result.selected, .portuguese)
    }

    func testRemovingSelectedMovesSelectionToFirstActive() {
        let result = ActiveLanguages.removing(.auto, from: [.auto, .english, .portuguese], selected: .auto)
        XCTAssertEqual(result.active, [.english, .portuguese])
        XCTAssertEqual(result.selected, .english)
    }

    func testLastLanguageCannotBeRemoved() {
        let result = ActiveLanguages.removing(.english, from: [.english], selected: .english)
        XCTAssertEqual(result.active, [.english])
        XCTAssertEqual(result.selected, .english)
        XCTAssertFalse(ActiveLanguages.canRemove(.english, from: [.english]))
        XCTAssertTrue(ActiveLanguages.canRemove(.english, from: [.auto, .english]))
        XCTAssertFalse(ActiveLanguages.canRemove(.portuguese, from: [.auto, .english]))
    }

    func testNormalizedDedupesAndAddsSelected() {
        XCTAssertEqual(ActiveLanguages.normalized([.auto, .english, .auto], selected: .english), [.auto, .english])
        XCTAssertEqual(ActiveLanguages.normalized([.auto], selected: .portuguese), [.auto, .portuguese])
        XCTAssertEqual(ActiveLanguages.normalized([], selected: .english), [.english])
    }

    func testDecodedConfigAddsSelectedLanguageToActiveList() throws {
        let json = #"{"selectedLanguage":"pt","cycleLanguages":["auto","en"]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.activeLanguages, [.auto, .english, .portuguese])
    }

    func testActiveLanguagesPersistUnderCycleLanguagesKey() throws {
        var config = Config()
        config.activeLanguages = [.english]
        config.selectedLanguage = .english
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        XCTAssertEqual(object?["cycleLanguages"] as? [String], ["en"])
    }
}
