import XCTest
@testable import WhisperNativeCore

final class WhisperPromptTests: XCTestCase {

    func testOrderIsLanguageExampleThenUserTextThenTerms() {
        let built = WhisperPrompt.build(
            languagePrompt: "Example sentence.",
            userPrompt: "  My own text.  ",
            vocabulary: ["Kubernetes", "Notably"]
        )
        XCTAssertEqual(built.text, "Example sentence. My own text. Kubernetes, Notably.")
        XCTAssertEqual(built.includedTerms, ["Kubernetes", "Notably"])
        XCTAssertEqual(built.droppedTerms, [])
    }

    func testEmptyPartsAreSkipped() {
        XCTAssertEqual(WhisperPrompt.build(languagePrompt: "", userPrompt: "", vocabulary: []).text, "")
        XCTAssertEqual(WhisperPrompt.build(languagePrompt: "", userPrompt: "", vocabulary: ["Grafana"]).text, "Grafana.")
        XCTAssertEqual(WhisperPrompt.build(languagePrompt: "", userPrompt: "Hi.", vocabulary: []).text, "Hi.")
        XCTAssertEqual(WhisperPrompt.build(languagePrompt: "Base.", userPrompt: " ", vocabulary: []).text, "Base.")
    }

    func testTermsAreTrimmedAndDeduplicated() {
        let built = WhisperPrompt.build(languagePrompt: "", userPrompt: "", vocabulary: [" Grafana ", "", "Grafana", "Loki"])
        XCTAssertEqual(built.text, "Grafana, Loki.")
        XCTAssertEqual(built.includedTerms, ["Grafana", "Loki"])
    }

    func testNoPeriodAddedAfterTermEndingWithPunctuation() {
        XCTAssertEqual(WhisperPrompt.build(languagePrompt: "", userPrompt: "", vocabulary: ["Acme Inc."]).text, "Acme Inc.")
    }

    func testTermsPastTheBudgetAreDroppedInFileOrderAndUserTextIsKept() {
        let userText = String(repeating: "a", count: 30) // 10 tokens
        // Each further term costs ", " + 4 chars = 2 tokens; the first one costs
        // " " + 4 chars + "." = 2 tokens.
        let terms = (0..<10).map { "t\(String(format: "%03d", $0))" }
        let built = WhisperPrompt.build(languagePrompt: "", userPrompt: userText, vocabulary: terms, tokenBudget: 20)
        XCTAssertEqual(built.includedTerms, Array(terms.prefix(5)))
        XCTAssertEqual(built.droppedTerms, Array(terms.dropFirst(5)))
        XCTAssertTrue(built.text.hasPrefix(userText + " t000, "))
        XCTAssertTrue(built.text.hasSuffix("t004."))
        XCTAssertLessThanOrEqual(WhisperPrompt.estimatedTokens(built.text), 20)
    }

    func testUserTextOverBudgetIsKeptWholeAndAllTermsDropped() {
        let userText = String(repeating: "word ", count: 300).trimmingCharacters(in: .whitespaces)
        let built = WhisperPrompt.build(languagePrompt: "", userPrompt: userText, vocabulary: ["Grafana"])
        XCTAssertEqual(built.text, userText)
        XCTAssertEqual(built.includedTerms, [])
        XCTAssertEqual(built.droppedTerms, ["Grafana"])
    }

    func testStopsAtFirstTermThatDoesNotFit() {
        // A long term that doesn't fit is not skipped over for later short ones,
        // so the kept terms are always the first ones in the file.
        let built = WhisperPrompt.build(
            languagePrompt: "",
            userPrompt: "",
            vocabulary: ["ab", String(repeating: "x", count: 60), "cd"],
            tokenBudget: 5
        )
        XCTAssertEqual(built.includedTerms, ["ab"])
        XCTAssertEqual(built.droppedTerms.count, 2)
    }

    func testDefaultBudgetLeavesRoomBelowWhisperLimit() {
        XCTAssertLessThan(WhisperPrompt.tokenBudget, WhisperPrompt.whisperMaxTokens)
        let terms = (0..<500).map { "Term\($0)" }
        let built = WhisperPrompt.build(
            languagePrompt: Constants.languagePrompts[.english] ?? "",
            userPrompt: "",
            vocabulary: terms
        )
        XCTAssertFalse(built.includedTerms.isEmpty)
        XCTAssertFalse(built.droppedTerms.isEmpty)
        XCTAssertLessThanOrEqual(WhisperPrompt.estimatedTokens(built.text), WhisperPrompt.tokenBudget)
    }

    func testEstimateCountsNonASCIICharactersAsWholeTokens() {
        XCTAssertEqual(WhisperPrompt.estimatedTokens(""), 0)
        XCTAssertEqual(WhisperPrompt.estimatedTokens("abc"), 1)
        XCTAssertEqual(WhisperPrompt.estimatedTokens("abcd"), 2)
        XCTAssertEqual(WhisperPrompt.estimatedTokens("câmbio"), 3) // 5 ASCII + 1 other = 8/3, rounded up
        XCTAssertEqual(WhisperPrompt.estimatedTokens("東京"), 2)
    }

    // MARK: - Config

    func testConfigBuildUsesLanguageExampleUserTextAndVocabularyWhenOn() {
        var config = Config()
        config.selectedLanguage = .english
        config.prompt = "Notes about the deploy."
        let built = WhisperPrompt.build(config: config, vocabulary: ["Grafana"])
        XCTAssertEqual(built.text, "\(Constants.languagePrompts[.english]!) Notes about the deploy. Grafana.")
    }

    func testConfigBuildIgnoresVocabularyWhenOff() {
        var config = Config()
        config.selectedLanguage = .auto
        config.prompt = "Hello."
        config.whisperUsesVocabulary = false
        let built = WhisperPrompt.build(config: config, vocabulary: ["Grafana"])
        XCTAssertEqual(built.text, "Hello.")
        XCTAssertEqual(built.includedTerms, [])
        XCTAssertEqual(built.droppedTerms, [])
    }

    func testWhisperUsesVocabularyDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(Config().whisperUsesVocabulary)
        let legacy = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.whisperUsesVocabulary)

        var config = Config()
        config.whisperUsesVocabulary = false
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(decoded.whisperUsesVocabulary)
    }
}
