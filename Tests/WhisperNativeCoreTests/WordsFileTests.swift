import XCTest
@testable import WhisperNativeCore

final class WordsFileTests: XCTestCase {
    private typealias Words = WordsFile
    private var scratchDirectory: URL?

    override func tearDownWithError() throws {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    /// words.yml, vocabulary.yml and vocabulary.txt inside a fresh nested scratch folder.
    private func scratchLocation() -> Words.Location {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordsFileTests-\(UUID().uuidString)", isDirectory: true)
        scratchDirectory = directory
        return Words.Location(folder: directory.appendingPathComponent("nested", isDirectory: true))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// `body` (language keys at its top level) parsed as the vocabulary section.
    private func parseVocabulary(_ body: String) throws -> Words.WordLists {
        let indented = body.components(separatedBy: "\n").map { $0.isEmpty ? "" : "  " + $0 }.joined(separator: "\n")
        return try XCTUnwrap(Words.parse("vocabulary:\n" + indented).vocabularySection)
    }

    private let defaultStopWordsText = "stop words:\n  all:\n    - over\n  Portuguese:\n    - câmbio\n"

    private let sample = """
    # comment
    vocabulary:
      all:
        - Kubernetes
        - "  BigQuery  "
      Portuguese:
        - câmbio
        - Kubernetes
      de:
        - Schadenfreude
    stop words:
      all:
        - over
      pt:
        - câmbio
      German:
        - Ende
    """

    // MARK: - Sections

    func testParsesBothSections() throws {
        let contents = try Words.parse(sample)
        XCTAssertEqual(contents.vocabulary.groups, [
            .init(scope: .allLanguages, terms: ["Kubernetes", "BigQuery"]),
            .init(scope: .language(.portuguese), terms: ["câmbio", "Kubernetes"]),
            .init(scope: .language(try XCTUnwrap(Language(rawValue: "de"))), terms: ["Schadenfreude"]),
        ])
        XCTAssertEqual(contents.stopWords.groups, [
            .init(scope: .allLanguages, terms: ["over"]),
            .init(scope: .language(.portuguese), terms: ["câmbio"]),
            .init(scope: .language(try XCTUnwrap(Language(rawValue: "de"))), terms: ["Ende"]),
        ])
        XCTAssertEqual(contents.warnings, [])
    }

    func testMissingStopWordsSectionUsesTheDefaults() throws {
        let contents = try Words.parse("vocabulary:\n  all:\n    - Gemini\n")
        XCTAssertNil(contents.stopWordsSection)
        XCTAssertEqual(contents.stopWords, Words.defaultStopWords)
        XCTAssertEqual(contents.stopWords.words(for: .portuguese), ["over", "câmbio"])
    }

    func testEmptyStopWordsSectionMeansNoStopWords() throws {
        for text in ["stop words:\n", "stop words: []\n", "stop words: {}\n", "stop words:\n  all:\n"] {
            let contents = try Words.parse(text)
            XCTAssertNotNil(contents.stopWordsSection, text)
            XCTAssertEqual(contents.stopWords.words(for: .auto), [], text)
        }
    }

    func testUnknownTopLevelKeysWarnAndAreIgnored() throws {
        let contents = try Words.parse("""
        all:
          - Kubernetes
        Stop Words:
          all:
            - roger
        """)
        XCTAssertNil(contents.vocabularySection)
        XCTAssertEqual(contents.stopWords.words(for: .english), ["roger"], "section keys ignore case")
        XCTAssertEqual(contents.warnings.count, 1)
        XCTAssertTrue(contents.warnings[0].contains("unknown section \"all\""), contents.warnings[0])
    }

    func testSectionHoldingAListWarnsAndFallsBack() throws {
        let contents = try Words.parse("stop words:\n  - roger\nvocabulary:\n  all:\n    - Gemini\nVOCABULARY:\n  all:\n    - Other\n")
        XCTAssertNil(contents.stopWordsSection)
        XCTAssertEqual(contents.stopWords, Words.defaultStopWords)
        XCTAssertEqual(contents.vocabulary.words(for: .auto), ["Gemini"], "first section of a name wins")
        XCTAssertEqual(contents.warnings.count, 2)
        XCTAssertEqual(contents.warnings(for: .stopWords), contents.warnings)
    }

    func testEmptyAndCommentOnlyContentsHaveNoSections() throws {
        XCTAssertEqual(try Words.parse(""), .init())
        XCTAssertEqual(try Words.parse("# just a comment\n"), .init())
        XCTAssertEqual(try Words.parse(Words.fileHeader), .init())
        XCTAssertEqual(try Words.parse("").stopWords, Words.defaultStopWords)
    }

    func testMalformedYamlThrowsReadableError() {
        XCTAssertThrowsError(try Words.parse("vocabulary:\n  all:\n    - [unclosed\n")) { error in
            let message = (error as? Words.ParseError)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("Line "), message)
        }
        XCTAssertThrowsError(try Words.parse("vocabulary:\n  all:\n    - a\n  all:\n    - b\n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("more than once"), error.localizedDescription)
        }
        XCTAssertThrowsError(try Words.parse("- just\n- a list\n"))
    }

    // MARK: - Lists in a section

    func testParsesGroupsWithAllFirstAndTrimmedTerms() throws {
        let lists = try parseVocabulary("""
        pt:
          - câmbio
        all:
          - Kubernetes
          - "  BigQuery  "
          -
          - Kubernetes
        """)
        XCTAssertEqual(lists.groups, [
            .init(scope: .allLanguages, terms: ["Kubernetes", "BigQuery"]),
            .init(scope: .language(.portuguese), terms: ["câmbio"]),
        ])
        XCTAssertEqual(lists.warnings, [])
    }

    func testEmptyKeyIsAnEmptyListAndSingleValueIsOneTerm() throws {
        let lists = try parseVocabulary("all:\nEnglish: Gemini\nPortuguese:\n")
        XCTAssertEqual(lists.groups, [
            .init(scope: .allLanguages, terms: []),
            .init(scope: .language(.english), terms: ["Gemini"]),
            .init(scope: .language(.portuguese), terms: []),
        ])
    }

    func testScalarsKeepTheirTextWhateverTheirYamlType() throws {
        let lists = try parseVocabulary("all:\n  - yes\n  - 3.10\n  - C#\n  - 'null'\n  - null\n")
        XCTAssertEqual(lists.groups.first?.terms, ["yes", "3.10", "C#", "null"])
    }

    func testUnknownKeysAndNestedValuesWarnAndAreIgnored() throws {
        let lists = try parseVocabulary("""
        all:
          - Gemini
          - nested: map
        Klingon:
          - Qapla
        en:
          key: value
        """)
        XCTAssertEqual(lists.groups, [
            .init(scope: .allLanguages, terms: ["Gemini"]),
            .init(scope: .language(.english), terms: []),
        ])
        XCTAssertEqual(lists.warnings.count, 3)
        XCTAssertTrue(lists.warnings[1].contains("Klingon"), lists.warnings[1])
    }

    func testKeysNamingTheSameLanguageMerge() throws {
        let lists = try parseVocabulary("pt:\n  - a\nall:\n  - b\nportuguese:\n  - c\n  - a\n")
        XCTAssertEqual(lists.groups, [
            .init(scope: .allLanguages, terms: ["b"]),
            .init(scope: .language(.portuguese), terms: ["a", "c"]),
        ])
    }

    // MARK: - Key matching

    func testLanguageKeysMatchCodeAndEnglishNameIgnoringCaseAndAccents() {
        XCTAssertEqual(Words.language(forKey: "pt"), .portuguese)
        XCTAssertEqual(Words.language(forKey: "Portuguese"), .portuguese)
        XCTAssertEqual(Words.language(forKey: " PORTUGUESE "), .portuguese)
        XCTAssertEqual(Words.language(forKey: "english"), .english)
        XCTAssertEqual(Words.language(forKey: "Maori"), Language(rawValue: "mi"))
        XCTAssertEqual(Words.language(forKey: "jw"), Language(rawValue: "jw"))
        XCTAssertEqual(Words.language(forKey: "Javanese"), Language(rawValue: "jw"))
        XCTAssertNil(Words.language(forKey: "all"))
        XCTAssertNil(Words.language(forKey: "auto"))
        XCTAssertNil(Words.language(forKey: "Klingon"))
    }

    func testEveryEnglishNameMapsBackToItsLanguage() {
        for language in Language.all where language != .auto {
            XCTAssertEqual(Words.language(forKey: language.englishName), language, language.englishName)
            XCTAssertEqual(Words.language(forKey: language.rawValue), language, language.rawValue)
        }
    }

    // MARK: - Selection

    func testFixedLanguageUsesAllPlusItsOwnList() throws {
        let contents = try Words.parse(sample)
        XCTAssertEqual(contents.vocabulary.selection(for: .portuguese).terms, ["Kubernetes", "BigQuery", "câmbio"])
        XCTAssertEqual(contents.vocabulary.selection(for: .english).terms, ["Kubernetes", "BigQuery"])
        XCTAssertEqual(contents.stopWords.words(for: .portuguese), ["over", "câmbio"])
        XCTAssertEqual(contents.stopWords.words(for: .english), ["over"])
    }

    func testAutoUsesEveryList() throws {
        let contents = try Words.parse(sample)
        XCTAssertEqual(contents.vocabulary.selection(for: .auto).terms, ["Kubernetes", "BigQuery", "câmbio", "Schadenfreude"])
        XCTAssertEqual(contents.stopWords.words(for: .auto), ["over", "câmbio", "Ende"])
    }

    func testSelectionCapsAtMaxTermsAndCountsTheRest() throws {
        let allTerms = (1...600).map { "  - a\($0)" }.joined(separator: "\n")
        let ptTerms = (1...405).map { "  - p\($0)" }.joined(separator: "\n")
        let lists = try parseVocabulary("all:\n\(allTerms)\npt:\n\(ptTerms)\n")
        let selection = lists.selection(for: .portuguese)
        XCTAssertEqual(selection.terms.count, Words.maxVocabularyTerms)
        XCTAssertEqual(selection.terms.first, "a1")
        XCTAssertEqual(selection.terms.last, "p400")
        XCTAssertEqual(selection.droppedCount, 5)
        XCTAssertEqual(lists.selection(for: .english).droppedCount, 0)
    }

    func testStopWordsAppendedToVocabularyAreDeduplicatedWithinTheCap() {
        XCTAssertEqual(
            Words.cappedVocabulary(["Kubernetes", "over"] + ["over", "câmbio"], language: .portuguese),
            ["Kubernetes", "over", "câmbio"]
        )
        let full = (1...Words.maxVocabularyTerms).map { "t\($0)" }
        XCTAssertEqual(Words.cappedVocabulary(full + ["over"], language: .english), full)
    }

    func testInlineDescriptionNamesTheLanguageOfLanguageWords() throws {
        XCTAssertEqual(
            Words.defaultStopWords.inlineDescription,
            "over, câmbio (\(Language.portuguese.displayName))"
        )
        XCTAssertEqual(Words.WordLists().inlineDescription, "")
    }

    // MARK: - Files

    func testMissingFileUsesNoVocabularyAndTheDefaultStopWords() {
        let location = scratchLocation()
        XCTAssertEqual(Words.read(at: location), .missing)
        XCTAssertEqual(Words.load(for: .portuguese, at: location), .init(vocabulary: [], stopWords: ["over", "câmbio"]))
        XCTAssertEqual(Words.vocabulary(for: .auto, at: location), [])
    }

    func testMalformedFileUsesNoVocabularyAndTheDefaultStopWords() throws {
        let location = scratchLocation()
        try write("vocabulary:\n  all:\n    - [unclosed\nstop words:\n  all:\n", to: location.url)
        guard case .malformed(let reason) = Words.read(at: location) else {
            return XCTFail("expected malformed")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(Words.load(for: .english, at: location), .init(vocabulary: [], stopWords: ["over"]))
    }

    func testLoadSelectsForLanguage() throws {
        let location = scratchLocation()
        try write(sample, to: location.url)
        XCTAssertEqual(
            Words.load(for: .portuguese, at: location),
            .init(vocabulary: ["Kubernetes", "BigQuery", "câmbio"], stopWords: ["over", "câmbio"])
        )
        XCTAssertEqual(Words.vocabulary(for: .english, at: location), ["Kubernetes", "BigQuery"])
    }

    // MARK: - Migration

    func testMigratesVocabularyYAMLIntoTheVocabularySectionOnceAndKeepsIt() throws {
        let location = scratchLocation()
        let legacy = "# Keys for your languages: Portuguese (pt)\n" + Words.legacyVocabularyHeader
            + "# my note\nall:\n  - Kubernetes  # why\n\nPortuguese:\n  - câmbio\n"
        try write(legacy, to: location.legacyYAMLURL)
        try write("Ignored\n", to: location.legacyTextURL)

        XCTAssertEqual(
            Words.load(for: .portuguese, at: location),
            .init(vocabulary: ["Kubernetes", "câmbio"], stopWords: ["over", "câmbio"])
        )
        XCTAssertEqual(try contents(of: location.legacyYAMLURL), legacy)
        let migrated = try contents(of: location.url)
        XCTAssertEqual(
            migrated,
            Words.fileHeader
                + "vocabulary:\n  # my note\n  all:\n    - Kubernetes  # why\n\n  Portuguese:\n    - câmbio\n"
                + defaultStopWordsText
        )

        // words.yml exists now, so edits to the old files are ignored.
        try write("all:\n  - Other\n", to: location.legacyYAMLURL)
        XCTAssertFalse(Words.migrateLegacyFilesIfNeeded(at: location))
        XCTAssertEqual(try contents(of: location.url), migrated)
    }

    func testMigratesVocabularyTextIntoVocabularyAllOnceAndKeepsIt() throws {
        let location = scratchLocation()
        let legacy = "# header\n  Kubernetes\n\nC#\nKubernetes\nnull\nsay \"hi\": now\n- dash\n"
        try write(legacy, to: location.legacyTextURL)

        XCTAssertEqual(
            Words.vocabulary(for: .english, at: location),
            ["Kubernetes", "C#", "null", "say \"hi\": now", "- dash"]
        )
        XCTAssertEqual(try contents(of: location.legacyTextURL), legacy)
        let migrated = try contents(of: location.url)
        XCTAssertTrue(migrated.hasPrefix(Words.fileHeader + "vocabulary:\n  all:\n    - Kubernetes\n"), migrated)
        XCTAssertTrue(migrated.hasSuffix(defaultStopWordsText), migrated)

        try write("Other\n", to: location.legacyTextURL)
        XCTAssertFalse(Words.migrateLegacyFilesIfNeeded(at: location))
        XCTAssertEqual(try contents(of: location.url), migrated)
    }

    func testMigratedScalarsRoundTrip() throws {
        let terms = ["Kubernetes", "O'Reilly", "C#", "C++", "#hashtag", "key: value", "~", "NULL", "back\\slash", "\"quoted\"", "*star", "3.10", "x & y, z"]
        let contents = try Words.parse(Words.migratedContents(terms: terms))
        XCTAssertEqual(contents.vocabulary.groups, [.init(scope: .allLanguages, terms: terms)])
        XCTAssertEqual(contents.stopWordsSection, Words.defaultStopWords)
    }

    func testNewFileParsesToEmptyVocabularyAndDefaultStopWords() throws {
        let contents = try Words.parse(Words.newFileContents)
        XCTAssertEqual(contents.vocabularySection, .init(groups: [.init(scope: .allLanguages, terms: [])]))
        XCTAssertEqual(contents.stopWordsSection, Words.defaultStopWords)
    }

    // MARK: - Editing

    func testNewFileGetsHeaderBothSectionsAndActiveLanguageKeys() throws {
        let contents = try XCTUnwrap(Words.contentsAddingMissingKeys(to: nil, languages: [.auto, .portuguese, .english]))
        XCTAssertEqual(
            contents,
            Words.fileHeader
                + "vocabulary:\n  all:\n  Portuguese:\n  English:\n"
                + defaultStopWordsText + "  English:\n"
        )
        let parsed = try Words.parse(contents)
        XCTAssertEqual(parsed.vocabulary.groups.map(\.scope), [.allLanguages, .language(.portuguese), .language(.english)])
        XCTAssertEqual(parsed.stopWords.words(for: .auto), ["over", "câmbio"])
    }

    func testInsertsMissingKeysAtTheEndOfEachSectionKeepingExistingText() throws {
        let existing = """
        # my notes
        vocabulary:
            all:
              - Kubernetes  # trailing comment
            pt:
              - câmbio
        # stop words below
        stop words:
          all:
            - over
        """
        let contents = try XCTUnwrap(Words.contentsAddingMissingKeys(to: existing, languages: [.auto, .portuguese, .english]))
        XCTAssertEqual(contents, """
        # my notes
        vocabulary:
            all:
              - Kubernetes  # trailing comment
            pt:
              - câmbio
            English:
        # stop words below
        stop words:
          all:
            - over
          Portuguese:
          English:
        """)
        XCTAssertNil(Words.contentsAddingMissingKeys(to: contents, languages: [.portuguese, .english]))
    }

    func testAppendsMissingSections() throws {
        XCTAssertEqual(
            Words.contentsAddingMissingKeys(to: "vocabulary:\n  all:\n    - X\n", languages: [.english]),
            "vocabulary:\n  all:\n    - X\n  English:\n" + defaultStopWordsText + "  English:\n"
        )
        XCTAssertEqual(
            Words.contentsAddingMissingKeys(to: "stop words:\n  all:\n    - roger", languages: []),
            "stop words:\n  all:\n    - roger\nvocabulary:\n  all:\n"
        )
    }

    func testEmptySectionsGetIndentedKeys() throws {
        XCTAssertEqual(
            Words.contentsAddingMissingKeys(to: "vocabulary:\nstop words:\n", languages: [.english]),
            "vocabulary:\n  English:\nstop words:\n  English:\n"
        )
    }

    func testDoesNotEditMalformedOrFlowStyleFiles() {
        XCTAssertNil(Words.contentsAddingMissingKeys(to: "vocabulary:\n  all:\n    - [unclosed\n", languages: [.english]))
        XCTAssertNil(Words.contentsAddingMissingKeys(to: "{vocabulary: {all: [Gemini]}}", languages: [.english]))
        XCTAssertEqual(
            Words.contentsAddingMissingKeys(to: "vocabulary: {all: [Gemini]}\nstop words:\n", languages: [.english]),
            "vocabulary: {all: [Gemini]}\nstop words:\n  English:\n"
        )
    }

    func testPrepareForEditingCreatesMigratesAndAppends() throws {
        let location = scratchLocation()
        try Words.prepareForEditing(at: location, languages: [.english])
        XCTAssertEqual(
            try contents(of: location.url),
            "# Keys for your languages: English (en)\n" + Words.fileHeader
                + "vocabulary:\n  all:\n  English:\n" + defaultStopWordsText + "  English:\n"
        )

        try FileManager.default.removeItem(at: location.url)
        try write("Gemini\n", to: location.legacyTextURL)
        try Words.prepareForEditing(at: location, languages: [.portuguese])
        XCTAssertEqual(
            try contents(of: location.url),
            "# Keys for your languages: Portuguese (pt)\n" + Words.fileHeader
                + "vocabulary:\n  all:\n    - Gemini\n  Portuguese:\n" + defaultStopWordsText
        )
    }

    func testActiveLanguagesCommentIsReplacedInPlace() {
        let first = Words.contentsWithActiveLanguagesComment("all:\n", languages: [.auto, .portuguese])
        XCTAssertEqual(first, "# Keys for your languages: Portuguese (pt)\nall:\n")
        let edited = "# my notes\n" + first
        XCTAssertEqual(
            Words.contentsWithActiveLanguagesComment(edited, languages: [.portuguese, .english]),
            "# my notes\n# Keys for your languages: Portuguese (pt), English (en)\nall:\n"
        )
        XCTAssertEqual(
            Words.contentsWithActiveLanguagesComment("all:\n", languages: [.auto]),
            "# Keys for your languages: none, only auto detect\nall:\n"
        )
    }
}
