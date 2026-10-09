import Foundation

/// The spoken words that end a dictation hands-free, radio style ("over",
/// "câmbio"), from the words file's `stop words` section. A stop word (one or
/// more words) counts only at the very end of the transcript, in any case and
/// with or without accents, on word boundaries ("takeover" never matches
/// "over"), with any whitespace or punctuation around and between its words;
/// "over the weekend" never matches either.
public struct StopWordMatcher: Equatable, Sendable {
    /// Trimmed, non-empty, unique ignoring case and accents, in the given order.
    public let words: [String]
    /// Each word's folded tokens, longest phrase first so it wins removal.
    private let phrases: [[String]]

    public init(words: [String]) {
        var seen: Set<[String]> = []
        var kept: [String] = []
        var phrases: [[String]] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = Self.tokenRanges(in: trimmed).map { Self.fold(trimmed[$0]) }
            guard !tokens.isEmpty, seen.insert(tokens).inserted else { continue }
            kept.append(trimmed)
            phrases.append(tokens)
        }
        self.words = kept
        self.phrases = phrases.enumerated()
            .sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }
            .map(\.element)
    }

    public var isEmpty: Bool { words.isEmpty }

    /// True when `text` ends with one of the stop words.
    public func endsWithStopWord(_ text: String) -> Bool {
        matchStart(in: text) != nil
    }

    /// `text` without the trailing stop word, plus the comma, dash, semicolon
    /// or colon that tied it to the sentence ("Ship it, over." -> "Ship it",
    /// "Ship it. Over." -> "Ship it."). Text that doesn't end with one comes
    /// back unchanged.
    public func removingStopWord(from text: String) -> String {
        guard let start = matchStart(in: text) else { return text }
        var kept = text[..<start]
        while let last = kept.last, last.isWhitespace || ",;:-–—".contains(last) {
            kept.removeLast()
        }
        return String(kept)
    }

    /// Where the stop word that ends `text` begins, the longest phrase winning.
    private func matchStart(in text: String) -> String.Index? {
        guard !phrases.isEmpty else { return nil }
        let longest = phrases.first?.count ?? 0
        let lastTokens = Array(Self.tokenRanges(in: text).suffix(longest))
        let foldedTokens = lastTokens.map { Self.fold(text[$0]) }
        for phrase in phrases where phrase.count <= foldedTokens.count {
            if Array(foldedTokens.suffix(phrase.count)) == phrase {
                return lastTokens[lastTokens.count - phrase.count].lowerBound
            }
        }
        return nil
    }

    /// Ranges of the words in `text`: runs of characters that are neither
    /// whitespace nor punctuation.
    private static func tokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character.isPunctuation {
                if let start = tokenStart {
                    ranges.append(start..<index)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }
            index = text.index(after: index)
        }
        if let start = tokenStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    private static func fold(_ token: Substring) -> String {
        String(token).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
