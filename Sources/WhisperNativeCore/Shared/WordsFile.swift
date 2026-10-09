import Foundation
import Yams

/// The user's word lists: a YAML file in the app's data folder
/// (`Constants.wordsFileURL`, `words.yml`) with two top-level sections.
/// `vocabulary` holds custom vocabulary for both Gemini engines, `stop words`
/// the spoken words that end a recording (`StopWordMatcher`). Each section maps
/// keys to lists of terms: `all` applies to every language; any other key names
/// a language by English name (case and diacritic insensitive, e.g.
/// `Portuguese`) or whisper code (`pt`). Unknown keys, at the top level or in a
/// section, are logged and ignored. Read at every request / recording start, so
/// edits (from Settings' Edit buttons or any other tool) apply to the next
/// dictation. A fixed language uses `all` plus its own list, auto detect every
/// list. Without a `stop words` section (or file) the defaults apply
/// (`defaultStopWords`); an empty section means no stop words. A malformed file
/// sends no vocabulary and uses the default stop words.
public enum WordsFile {
    // MARK: - Model

    /// Gemini's `custom_vocabulary` limit.
    public static let maxVocabularyTerms = 1000
    /// Gemini's docs report the best results up to about this many terms.
    public static let recommendedMaxVocabularyTerms = 100
    /// Key whose terms go with every language.
    public static let allLanguagesKey = "all"

    /// A top-level section of the file.
    public enum Section: String, CaseIterable, Sendable {
        case vocabulary
        case stopWords

        /// The section's top-level key.
        public var key: String {
            switch self {
            case .vocabulary: return "vocabulary"
            case .stopWords: return "stop words"
            }
        }
    }

    /// Where the file and the older vocabulary files it is migrated from live.
    public struct Location: Sendable {
        public var url: URL
        /// Earlier `vocabulary.yml` (language keys at the top level).
        public var legacyYAMLURL: URL
        /// Earliest `vocabulary.txt` (one term per line).
        public var legacyTextURL: URL

        public init(url: URL, legacyYAMLURL: URL, legacyTextURL: URL) {
            self.url = url
            self.legacyYAMLURL = legacyYAMLURL
            self.legacyTextURL = legacyTextURL
        }

        /// `words.yml`, `vocabulary.yml` and `vocabulary.txt` inside `folder`.
        public init(folder: URL) {
            self.init(
                url: folder.appendingPathComponent("words.yml", isDirectory: false),
                legacyYAMLURL: folder.appendingPathComponent("vocabulary.yml", isDirectory: false),
                legacyTextURL: folder.appendingPathComponent("vocabulary.txt", isDirectory: false)
            )
        }

        public static let standard = Location(
            url: Constants.wordsFileURL,
            legacyYAMLURL: Constants.legacyVocabularyYAMLURL,
            legacyTextURL: Constants.legacyVocabularyTextURL
        )
    }

    /// Which dictations a list of terms applies to.
    public enum Scope: Hashable, Sendable {
        case allLanguages
        case language(Language)
    }

    /// One scope's terms: trimmed, non-empty, unique within the group, in file order.
    public struct Group: Equatable, Sendable {
        public var scope: Scope
        public var terms: [String]

        public init(scope: Scope, terms: [String]) {
            self.scope = scope
            self.terms = terms
        }
    }

    /// One section's lists, keyed by language.
    public struct WordLists: Equatable, Sendable {
        /// The `all` group first (when the section has the key), then one group
        /// per language in file order. Keys naming the same language share a group.
        public var groups: [Group]
        /// Readable notes about ignored keys and values.
        public var warnings: [String]

        public init(groups: [Group] = [], warnings: [String] = []) {
            self.groups = groups
            self.warnings = warnings
        }

        /// Terms used when dictating in `language`: `all` plus that language's
        /// list, or every list for auto detect, exact duplicates dropped.
        public func words(for language: Language) -> [String] {
            let terms = groups
                .filter { group in
                    switch group.scope {
                    case .allLanguages: return true
                    case .language(let groupLanguage): return language == .auto || groupLanguage == language
                    }
                }
                .flatMap(\.terms)
            return WordsFile.unique(terms)
        }

        /// Vocabulary terms sent when dictating in `language`, capped.
        public func selection(for language: Language) -> Selection {
            WordsFile.capped(words(for: language))
        }

        /// Every term on one line, language terms followed by the language's
        /// name: `over, câmbio (Portuguese)`. Empty when there are no terms.
        public var inlineDescription: String {
            groups.flatMap { group -> [String] in
                switch group.scope {
                case .allLanguages: return group.terms
                case .language(let language): return group.terms.map { "\($0) (\(language.displayName))" }
                }
            }
            .joined(separator: ", ")
        }
    }

    /// Vocabulary terms for one request.
    public struct Selection: Equatable, Sendable {
        /// Unique terms in file order, capped at `maxVocabularyTerms`.
        public var terms: [String]
        /// Unique terms past the cap, not sent.
        public var droppedCount: Int

        public init(terms: [String], droppedCount: Int) {
            self.terms = terms
            self.droppedCount = droppedCount
        }
    }

    /// Stop words used when the file has no `stop words` section, has an
    /// unusable one, or doesn't parse.
    public static let defaultStopWords = WordLists(groups: [
        Group(scope: .allLanguages, terms: ["over"]),
        Group(scope: .language(.portuguese), terms: ["câmbio"]),
    ])

    /// A parsed file.
    public struct Contents: Equatable, Sendable {
        /// nil when the file has no usable `vocabulary` section.
        public var vocabularySection: WordLists?
        /// nil when the file has no usable `stop words` section.
        public var stopWordsSection: WordLists?
        /// Readable notes about ignored top-level keys and values.
        public var warnings: [String]

        public init(vocabularySection: WordLists? = nil, stopWordsSection: WordLists? = nil, warnings: [String] = []) {
            self.vocabularySection = vocabularySection
            self.stopWordsSection = stopWordsSection
            self.warnings = warnings
        }

        public var vocabulary: WordLists { vocabularySection ?? WordLists() }
        /// The section's lists, or the defaults when it has none.
        public var stopWords: WordLists { stopWordsSection ?? WordsFile.defaultStopWords }

        public func section(_ section: Section) -> WordLists? {
            switch section {
            case .vocabulary: return vocabularySection
            case .stopWords: return stopWordsSection
            }
        }

        /// Top-level warnings followed by the section's own.
        public func warnings(for section: Section) -> [String] {
            warnings + (self.section(section)?.warnings ?? [])
        }
    }

    /// State of the file on disk.
    public enum FileState: Equatable, Sendable {
        case missing
        case loaded(Contents)
        /// The file couldn't be read or parsed; carries a readable reason.
        case malformed(String)

        /// Vocabulary in effect: none unless the file loaded.
        public var vocabulary: WordLists {
            if case .loaded(let contents) = self { return contents.vocabulary }
            return WordLists()
        }

        /// Stop words in effect: the defaults unless the file loaded with a section.
        public var stopWords: WordLists {
            if case .loaded(let contents) = self { return contents.stopWords }
            return WordsFile.defaultStopWords
        }
    }

    /// The words one recording uses, unique, vocabulary uncapped.
    public struct RecordingWords: Equatable, Sendable {
        public var vocabulary: [String]
        public var stopWords: [String]

        public init(vocabulary: [String], stopWords: [String]) {
            self.vocabulary = vocabulary
            self.stopWords = stopWords
        }
    }

    /// Parse failure with a message meant for Settings and the log.
    public struct ParseError: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - File header

    /// Comment block that starts a file created by the app.
    public static let fileHeader = """
    # Word lists for Whisper Native, in two sections:
    #   vocabulary   names, brands, jargon and acronyms for the Gemini engines
    #                (up to 1000 terms per dictation, best results with about 100)
    #   stop words   words that end the recording when said as the last word
    #                ("Say a stop word to stop" setting, Parakeet and Gemini Live)
    # In each section, `all` lists terms for every language; any other key names
    # a language by English name or code (Portuguese or pt) and applies only
    # while dictating in it. Auto detect uses every list. Without a stop words
    # section the defaults apply (over, câmbio in Portuguese); an empty one
    # turns them off. Edits apply to the next dictation.
    #
    # Example:
    #   vocabulary:
    #     all:
    #       - Kubernetes
    #   stop words:
    #     all:
    #       - over
    #     Portuguese:
    #       - câmbio

    """

    /// Header of the earlier `vocabulary.yml`, dropped when migrating it.
    static let legacyVocabularyHeader = """
    # Custom vocabulary for the Gemini and Gemini Live engines: names, brands,
    # jargon, acronyms. Each top-level key holds a list of terms:
    #   all         terms sent whatever the language
    #   Portuguese  terms sent only while dictating in that language; use the
    #               English language name or its code (pt)
    # Auto detect sends every list. Up to 1000 terms are sent per dictation,
    # best results with about 100. Edits apply to the next dictation.
    #
    # Example:
    #   all:
    #     - Kubernetes
    #   Portuguese:
    #     - câmbio

    """

    // MARK: - Parsing

    /// Parses a words file. Empty or comment-only contents have no sections;
    /// invalid YAML or a top level that isn't a mapping throws. A section key
    /// with no value (or `[]`) is an empty section; a section holding anything
    /// but keys is ignored with a warning.
    public static func parse(_ contents: String) throws -> Contents {
        let root: Node?
        do {
            root = try Yams.compose(yaml: contents)
        } catch let error as YamlError {
            throw ParseError(message: readableMessage(for: error))
        } catch {
            throw ParseError(message: error.localizedDescription)
        }
        guard let root, root.null == nil else { return Contents() }
        guard let mapping = root.mapping else {
            throw ParseError(message: "Expected the sections \(Section.vocabulary.key) and \(Section.stopWords.key), each holding keys (all, a language name or a language code) followed by lists of terms.")
        }

        var parsed = Contents()
        var seenSections: Set<Section> = []
        for (keyNode, valueNode) in mapping {
            let location = lineDescription(keyNode.mark)
            guard let key = keyNode.scalar?.string.trimmingCharacters(in: .whitespacesAndNewlines) else {
                parsed.warnings.append("\(location)a key that isn't plain text was ignored.")
                continue
            }
            guard let section = section(forKey: key) else {
                parsed.warnings.append("\(location)unknown section \"\(key)\" ignored. Use \(Section.vocabulary.key) or \(Section.stopWords.key).")
                continue
            }
            guard seenSections.insert(section).inserted else {
                parsed.warnings.append("\(location)section \"\(key)\" appears more than once; only the first is used.")
                continue
            }
            let lists: WordLists
            if valueNode.null != nil || valueNode.sequence?.isEmpty == true {
                lists = WordLists()
            } else if let sectionMapping = valueNode.mapping {
                lists = wordLists(in: sectionMapping)
            } else {
                parsed.warnings.append("\(location)section \"\(key)\" doesn't hold keys (all or a language) and was ignored.")
                continue
            }
            switch section {
            case .vocabulary: parsed.vocabularySection = lists
            case .stopWords: parsed.stopWordsSection = lists
            }
        }
        return parsed
    }

    /// The section a top-level key names, case insensitive.
    static func section(forKey key: String) -> Section? {
        let folded = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Section.allCases.first { $0.key == folded }
    }

    /// One section's lists: `all` and language keys, each holding a list of terms.
    private static func wordLists(in mapping: Node.Mapping) -> WordLists {
        var allTerms: [String]?
        var languageOrder: [Language] = []
        var termsByLanguage: [Language: [String]] = [:]
        var warnings: [String] = []
        for (keyNode, valueNode) in mapping {
            let location = lineDescription(keyNode.mark)
            guard let key = keyNode.scalar?.string.trimmingCharacters(in: .whitespacesAndNewlines) else {
                warnings.append("\(location)a key that isn't plain text was ignored.")
                continue
            }
            let scope: Scope
            if key.lowercased() == allLanguagesKey {
                scope = .allLanguages
            } else if let language = language(forKey: key) {
                scope = .language(language)
            } else {
                warnings.append("\(location)unknown key \"\(key)\" ignored. Use all, an English language name or a language code.")
                continue
            }
            let terms = terms(in: valueNode, key: key, warnings: &warnings)
            switch scope {
            case .allLanguages:
                allTerms = (allTerms ?? []) + terms
            case .language(let language):
                if termsByLanguage[language] == nil { languageOrder.append(language) }
                termsByLanguage[language, default: []] += terms
            }
        }

        var groups: [Group] = []
        if let allTerms {
            groups.append(Group(scope: .allLanguages, terms: unique(allTerms)))
        }
        for language in languageOrder {
            groups.append(Group(scope: .language(language), terms: unique(termsByLanguage[language] ?? [])))
        }
        return WordLists(groups: groups, warnings: warnings)
    }

    /// The language a key names: its whisper code or its English name (also the
    /// name in the system language), case and diacritic insensitive. `all` and
    /// unknown names give nil.
    public static func language(forKey key: String) -> Language? {
        languagesByFoldedKey[fold(key.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    private static let languagesByFoldedKey: [String: Language] = {
        var lookup: [String: Language] = [:]
        let languages = Language.all.filter { $0 != .auto }
        // Later passes win collisions: codes over English names over local names.
        for name in [\Language.displayName, \Language.englishName, \Language.rawValue] {
            for language in languages {
                lookup[fold(language[keyPath: name])] = language
            }
        }
        return lookup
    }()

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Terms under one key: a list of scalars, a single scalar, or nothing.
    private static func terms(in node: Node, key: String, warnings: inout [String]) -> [String] {
        let items: [Node]
        if node.scalar != nil {
            items = [node]
        } else if let sequence = node.sequence {
            items = Array(sequence)
        } else {
            warnings.append("\(lineDescription(node.mark))the value of \"\(key)\" isn't a list of terms and was ignored.")
            return []
        }

        var terms: [String] = []
        for item in items {
            guard let scalar = item.scalar else {
                warnings.append("\(lineDescription(item.mark))a nested value under \"\(key)\" was ignored.")
                continue
            }
            guard item.null == nil else { continue }
            let term = scalar.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty { terms.append(term) }
        }
        return terms
    }

    private static func lineDescription(_ mark: Mark?) -> String {
        guard let mark else { return "" }
        return "Line \(mark.line): "
    }

    private static func readableMessage(for error: YamlError) -> String {
        switch error {
        case let .scanner(context, problem, mark, _),
             let .parser(context, problem, mark, _),
             let .composer(context, problem, mark, _):
            let detail = context.map { "\(problem) (\($0.text))" } ?? problem
            return "Line \(mark.line), column \(mark.column): \(detail)"
        case let .duplicatedKeysInMapping(duplicates, context):
            let keys = duplicates.map { "\"\($0)\"" }.joined(separator: ", ")
            return "Line \(context.mark.line): key \(keys) appears more than once."
        default:
            return error.description
        }
    }

    /// Unique strings in first-seen order.
    static func unique(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms.filter { seen.insert($0).inserted }
    }

    /// Exact duplicates dropped, first `maxVocabularyTerms` kept.
    static func capped(_ terms: [String]) -> Selection {
        let uniqueTerms = unique(terms)
        return Selection(
            terms: Array(uniqueTerms.prefix(maxVocabularyTerms)),
            droppedCount: max(0, uniqueTerms.count - maxVocabularyTerms)
        )
    }

    // MARK: - Reading

    /// State of the file, migrating an older vocabulary file first when it is missing.
    public static func read(at location: Location = .standard) -> FileState {
        migrateLegacyFilesIfNeeded(at: location)
        let url = location.url
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return .malformed("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            return .loaded(try parse(contents))
        } catch {
            return .malformed(error.localizedDescription)
        }
    }

    /// Words for one recording in `language`, read once. Ignored keys and a
    /// malformed file are logged as warnings; a malformed file gives no
    /// vocabulary and the default stop words.
    public static func load(for language: Language, at location: Location = .standard) -> RecordingWords {
        let state = read(at: location)
        let fileName = location.url.lastPathComponent
        switch state {
        case .missing:
            break
        case .malformed(let reason):
            AppLogger.shared.log(.warning, "Words file: \(fileName) is malformed, sending no vocabulary and using the default stop words: \(reason)")
        case .loaded(let contents):
            let warnings = contents.warnings
                + (contents.vocabularySection?.warnings ?? [])
                + (contents.stopWordsSection?.warnings ?? [])
            for warning in warnings {
                AppLogger.shared.log(.warning, "Words file: \(warning)")
            }
        }
        return RecordingWords(
            vocabulary: state.vocabulary.words(for: language),
            stopWords: state.stopWords.words(for: language)
        )
    }

    /// Vocabulary terms for the next Gemini request in `language`, capped.
    public static func vocabulary(for language: Language, at location: Location = .standard) -> [String] {
        cappedVocabulary(load(for: language, at: location).vocabulary, language: language)
    }

    /// `terms` deduplicated and capped at `maxVocabularyTerms`, logging a
    /// warning when some are dropped.
    public static func cappedVocabulary(_ terms: [String], language: Language) -> [String] {
        let selection = capped(terms)
        if selection.droppedCount > 0 {
            AppLogger.shared.log(
                .warning,
                "Words file: \(selection.terms.count + selection.droppedCount) vocabulary terms for \(language.rawValue), sending the first \(maxVocabularyTerms)"
            )
        }
        return selection.terms
    }

    // MARK: - Migration

    /// Writes the file from an older vocabulary file when it is missing:
    /// `vocabulary.yml` becomes the `vocabulary` section, else the terms of
    /// `vocabulary.txt` go under its `all`; the default stop words section
    /// follows. Older files stay in place, unused. Returns whether it wrote the file.
    @discardableResult
    public static func migrateLegacyFilesIfNeeded(at location: Location = .standard) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: location.url.path) else { return false }
        let source: URL
        let contents: String
        do {
            if fileManager.fileExists(atPath: location.legacyYAMLURL.path) {
                source = location.legacyYAMLURL
                contents = migratedContents(fromVocabularyYAML: try String(contentsOf: source, encoding: .utf8))
            } else if fileManager.fileExists(atPath: location.legacyTextURL.path) {
                source = location.legacyTextURL
                contents = migratedContents(terms: legacyTerms(in: try String(contentsOf: source, encoding: .utf8)))
            } else {
                return false
            }
            try write(contents, to: location.url)
        } catch {
            AppLogger.shared.log(.error, "Words file: failed to convert the old vocabulary file: \(error.localizedDescription)")
            return false
        }
        AppLogger.shared.log(.info, "Words file: converted \(source.lastPathComponent) into \(location.url.lastPathComponent)")
        return true
    }

    /// Terms of a `vocabulary.txt`: one per line, trimmed, blank and `#` lines
    /// skipped, exact duplicates dropped.
    static func legacyTerms(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return unique(lines)
    }

    /// `fileHeader`, `terms` as the vocabulary's `all` list, then the default
    /// stop words.
    static func migratedContents(terms: [String]) -> String {
        fileHeader
            + "\(Section.vocabulary.key):\n  \(allLanguagesKey):\n"
            + terms.map { "    - \(yamlScalar($0))\n" }.joined()
            + defaultStopWordsSectionText
    }

    /// A `vocabulary.yml`'s text indented under the `vocabulary` key (terms and
    /// comments kept, its app-written header and active languages comment
    /// dropped), after `fileHeader` and before the default stop words.
    static func migratedContents(fromVocabularyYAML legacy: String) -> String {
        var body = legacy
        if let headerRange = body.range(of: legacyVocabularyHeader) {
            body.removeSubrange(headerRange)
        }
        var lines = body.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(activeLanguagesCommentPrefix) }
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "  " + $0 }
        while lines.last == "" { lines.removeLast() }
        while lines.first == "" { lines.removeFirst() }
        return fileHeader
            + "\(Section.vocabulary.key):\n"
            + lines.map { $0 + "\n" }.joined()
            + defaultStopWordsSectionText
    }

    /// The `stop words` section holding `defaultStopWords`.
    static var defaultStopWordsSectionText: String {
        "\(Section.stopWords.key):\n" + defaultStopWords.groups.map { group in
            "  \(key(for: group.scope)):\n" + group.terms.map { "    - \(yamlScalar($0))\n" }.joined()
        }.joined()
    }

    /// The key a file written by the app uses for `scope`.
    static func key(for scope: Scope) -> String {
        switch scope {
        case .allLanguages: return allLanguagesKey
        case .language(let language): return language.englishName
        }
    }

    /// `term` as a YAML scalar: plain when it is only letters, digits, spaces
    /// and a few safe punctuation marks (and isn't a null literal), otherwise
    /// double-quoted.
    static func yamlScalar(_ term: String) -> String {
        let safePunctuation = Set("._+/'()&,-")
        let isPlainSafe = term.first.map { $0.isLetter || $0.isNumber } == true
            && term.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || safePunctuation.contains($0) }
            && !["null", "Null", "NULL"].contains(term)
        if isPlainSafe { return term }
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Editing

    /// Contents of a new file: `fileHeader`, an empty vocabulary `all` key and
    /// the default stop words.
    static var newFileContents: String {
        fileHeader + "\(Section.vocabulary.key):\n  \(allLanguagesKey):\n" + defaultStopWordsSectionText
    }

    /// `contents` readied for editing: a section missing from the file is
    /// appended (an empty vocabulary `all` key, the default stop words), then
    /// each section gets an empty key (English language name) for every one of
    /// `languages` it has no key for, auto skipped, inserted at the end of that
    /// section. Existing text is kept as is. A missing file (`contents` nil)
    /// starts from `newFileContents`. Returns nil when the file needs no
    /// change or doesn't parse; an insertion that wouldn't parse (e.g. a
    /// flow-style section) is skipped.
    public static func contentsAddingMissingKeys(to contents: String?, languages: [Language]) -> String? {
        let base = contents ?? newFileContents
        let unchanged = contents == nil ? base : nil
        guard (try? parse(base)) != nil, let layouts = sectionLayouts(in: base) else { return unchanged }

        var text = base
        for section in Section.allCases where layouts[section] == nil {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            switch section {
            case .vocabulary: text += "\(Section.vocabulary.key):\n  \(allLanguagesKey):\n"
            case .stopWords: text += defaultStopWordsSectionText
            }
        }
        // Appending to a flow-style top level breaks it: leave such a file alone.
        guard (try? parse(text)) != nil else { return unchanged }

        for section in Section.allCases {
            guard let lists = (try? parse(text))?.section(section) else { continue }
            var present = Set(lists.groups.compactMap { group -> Language? in
                if case .language(let language) = group.scope { return language }
                return nil
            })
            let missing = languages.filter { $0 != .auto && present.insert($0).inserted }
            guard !missing.isEmpty, let layout = sectionLayouts(in: text)?[section] else { continue }
            let updated = inserting(keys: missing.map(\.englishName), into: layout, in: text)
            guard let reparsed = (try? parse(updated))?.section(section) else { continue }
            let reparsedScopes = Set(reparsed.groups.map(\.scope))
            guard missing.allSatisfy({ reparsedScopes.contains(.language($0)) }) else { continue }
            text = updated
        }
        return text == base ? unchanged : text
    }

    /// Where a section sits in the file's text (1-based line numbers).
    private struct SectionLayout {
        let keyLine: Int
        /// Line of the next top-level key, nil when the section runs to the end.
        let nextKeyLine: Int?
        /// Column of the section's first key, nil when it has none.
        let childColumn: Int?
    }

    /// Layout of each section key at the top level, nil when `text` doesn't
    /// parse or its top level isn't a mapping.
    private static func sectionLayouts(in text: String) -> [Section: SectionLayout]? {
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            return nil
        }
        guard let root, root.null == nil else { return [:] }
        guard let mapping = root.mapping else { return nil }
        let keyLines = mapping.compactMap { $0.key.mark?.line }.sorted()
        var layouts: [Section: SectionLayout] = [:]
        for (keyNode, valueNode) in mapping {
            guard let key = keyNode.scalar?.string,
                  let section = section(forKey: key),
                  layouts[section] == nil,
                  let keyLine = keyNode.mark?.line else { continue }
            layouts[section] = SectionLayout(
                keyLine: keyLine,
                nextKeyLine: keyLines.first { $0 > keyLine },
                childColumn: valueNode.mapping?.first?.key.mark?.column
            )
        }
        return layouts
    }

    /// `text` with `keys` (empty values) as new lines after the section's last
    /// indented line, at its keys' indentation (two spaces when it has none).
    private static func inserting(keys: [String], into layout: SectionLayout, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let keyIndex = layout.keyLine - 1
        let endIndex = min(layout.nextKeyLine.map { $0 - 1 } ?? lines.count, lines.count)
        var lastSectionLine = keyIndex
        if keyIndex + 1 < endIndex {
            for index in (keyIndex + 1)..<endIndex {
                let line = lines[index]
                let isIndented = line.first == " " || line.first == "\t"
                if isIndented, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lastSectionLine = index
                }
            }
        }
        let indent = String(repeating: " ", count: max(1, (layout.childColumn ?? 3) - 1))
        lines.insert(contentsOf: keys.map { "\(indent)\($0):" }, at: lastSectionLine + 1)
        return lines.joined(separator: "\n")
    }

    /// Start of the comment line that lists the active languages' keys.
    static let activeLanguagesCommentPrefix = "# Keys for your languages:"

    /// `contents` with its first line listing the keys of `languages` (auto
    /// skipped), e.g. `# Keys for your languages: Portuguese (pt), English (en)`.
    /// An existing such line is replaced wherever it sits; otherwise the line
    /// goes on top. Comments never change what the file parses to.
    static func contentsWithActiveLanguagesComment(_ contents: String, languages: [Language]) -> String {
        let keys = languages.filter { $0 != .auto }.map { "\($0.englishName) (\($0.rawValue))" }
        let comment = "\(activeLanguagesCommentPrefix) " + (keys.isEmpty ? "none, only auto detect" : keys.joined(separator: ", "))
        var lines = contents.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix(activeLanguagesCommentPrefix) }) {
            lines[index] = comment
            return lines.joined(separator: "\n")
        }
        return comment + "\n" + contents
    }

    /// Readies the file for the Edit buttons: migrates an older vocabulary file
    /// or creates the file when missing, adds missing sections and an empty
    /// key for each of `languages` a section has none for, and refreshes the
    /// active language keys comment.
    public static func prepareForEditing(at location: Location = .standard, languages: [Language]) throws {
        migrateLegacyFilesIfNeeded(at: location)
        let url = location.url
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : nil
        guard let withKeys = contentsAddingMissingKeys(to: existing, languages: languages) ?? existing else { return }
        let updated = contentsWithActiveLanguagesComment(withKeys, languages: languages)
        guard updated != existing else { return }
        try write(updated, to: url)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
