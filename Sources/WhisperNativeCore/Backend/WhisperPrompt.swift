import Foundation

/// Builds the whisper.cpp `prompt` field: the per-language exemplar
/// (`Constants.languagePrompts`), then the user's "Initial prompt" text, then
/// the words file's vocabulary terms as one comma-separated sentence
/// (`Kubernetes, Notably, Grafana.`), each part separated by a space.
///
/// whisper.cpp keeps only the last `whisperMaxTokens` tokens of a prompt and
/// drops the start, which would cut the exemplar and the user's text first. So
/// the exemplar and the user's text are always kept whole, and terms are added
/// in file order only while the estimated size stays within `tokenBudget`; the
/// rest are left out (the caller logs a warning).
public enum WhisperPrompt {
    /// Prompt tokens whisper.cpp keeps (`n_text_ctx / 2`).
    public static let whisperMaxTokens = 224
    /// Estimated-token budget for the whole prompt, below `whisperMaxTokens`
    /// since `estimatedTokens` is approximate.
    public static let tokenBudget = 200

    public struct Built: Equatable, Sendable {
        /// The prompt to send, empty when there is nothing to send.
        public var text: String
        /// Vocabulary terms in the prompt, in file order.
        public var includedTerms: [String]
        /// Vocabulary terms left out to stay within the budget.
        public var droppedTerms: [String]

        public init(text: String, includedTerms: [String], droppedTerms: [String]) {
            self.text = text
            self.includedTerms = includedTerms
            self.droppedTerms = droppedTerms
        }
    }

    /// Prompt for `config`: its language's exemplar, `config.prompt`, and
    /// `vocabulary` when `config.whisperUsesVocabulary` is on.
    public static func build(config: Config, vocabulary: [String]) -> Built {
        build(
            languagePrompt: Constants.languagePrompts[config.selectedLanguage] ?? "",
            userPrompt: config.prompt,
            vocabulary: config.whisperUsesVocabulary ? vocabulary : []
        )
    }

    public static func build(
        languagePrompt: String,
        userPrompt: String,
        vocabulary: [String],
        tokenBudget: Int = tokenBudget
    ) -> Built {
        let fixedText = [languagePrompt, userPrompt]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let terms = WordsFile.unique(
            vocabulary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        // Sizes in thirds of a token so the running total stays an integer.
        let budgetThirds = tokenBudget * 3
        var usedThirds = estimatedThirds(fixedText)
        var included: [String] = []
        for term in terms {
            // Separator before the term (" " after the fixed text, ", " between
            // terms) plus the term and the closing period.
            let separator = included.isEmpty ? (fixedText.isEmpty ? "" : " ") : ", "
            let added = estimatedThirds(separator + term)
            let closing = included.isEmpty ? estimatedThirds(".") : 0
            guard usedThirds + added + closing <= budgetThirds else { break }
            usedThirds += added + closing
            included.append(term)
        }

        var parts = fixedText.isEmpty ? [] : [fixedText]
        if !included.isEmpty {
            parts.append(termsSentence(included))
        }
        return Built(
            text: parts.joined(separator: " "),
            includedTerms: included,
            droppedTerms: Array(terms.dropFirst(included.count))
        )
    }

    /// Terms joined by commas, ending with a period unless the last term
    /// already ends with sentence punctuation.
    static func termsSentence(_ terms: [String]) -> String {
        let joined = terms.joined(separator: ", ")
        guard let last = joined.last, !".!?".contains(last) else { return joined }
        return joined + "."
    }

    /// Rough whisper token count: ASCII text at 3 characters per token (real
    /// English is closer to 4), every other character a token of its own
    /// (accented letters, Cyrillic and CJK usually cost one or more).
    public static func estimatedTokens(_ text: String) -> Int {
        (estimatedThirds(text) + 2) / 3
    }

    private static func estimatedThirds(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.isASCII ? 1 : 3)
        }
    }
}
