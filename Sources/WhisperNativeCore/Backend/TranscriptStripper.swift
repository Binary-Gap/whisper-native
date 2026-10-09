import Foundation

// Strips the voice-calibration prefix out of a combined (calibration + dictation)
// transcription by locating a fixed anchor phrase spoken at the end of the
// calibration sample. Everything up to and including the anchor is calibration.
//
// Matching an anchor phrase (rather than the whole sample text, or cutting by
// segment timestamps) is what makes this reliable: whisper re-words and
// re-segments the long calibration sentence differently each run, and VAD
// compresses segment timestamps so a duration boundary never lines up. A short
// distinctive phrase, by contrast, whisper transcribes verbatim every time.
//
// Matching is done on a normalized (lowercased, punctuation/whitespace-stripped)
// view of both strings so spacing/punctuation/casing drift doesn't break it
// (e.g. "end-of-calibration, sample" still matches "end of calibration sample").
//
// Matching is also FUZZY: whisper mis-transcribes short words acoustically
// (e.g. "End of" -> "and of", dropping the hard 'd'), which an exact substring
// search would miss. A sliding window scores every candidate span against the
// anchor by edit distance and accepts the best one that clears a similarity
// threshold, tolerating a couple of dropped/changed/added characters.
public enum TranscriptStripper {

    // Minimum normalized similarity (1 - editDistance/anchorLength) for a window
    // to count as the anchor. 0.85 lets a ~22-char anchor absorb ~3 edits while
    // staying well clear of what unrelated text scores against a fixed phrase.
    private static let minSimilarity = 0.85

    // Never fuzzy-match anchors shorter than this (normalized): too few chars and
    // a high threshold still matches incidental text. Short anchors fall back to
    // exact matching implicitly (an exact hit is similarity 1.0).
    private static let minFuzzyAnchorLength = 8

    /// Removes everything up to and including `anchorPhrase` from the start of
    /// `transcribedText`.
    ///
    /// Falls back to returning `transcribedText` unchanged when the anchor can't
    /// be located — wrongly truncating real dictation is worse than occasionally
    /// leaking the calibration text, so this never guesses.
    public static func stripCalibrationPrefix(from transcribedText: String, anchorPhrase: String) -> String {
        let normalizedAnchor = normalize(anchorPhrase)
        guard !normalizedAnchor.isEmpty else { return transcribedText }

        // Build a normalized view of the transcript, remembering each normalized
        // character's index in the original string so a match position in
        // normalized-space maps back to a cut point in original-space.
        var normalizedChars: [Character] = []
        var originalIndices: [String.Index] = []
        var index = transcribedText.startIndex
        while index < transcribedText.endIndex {
            if let normalizedChar = normalize(transcribedText[index]) {
                normalizedChars.append(normalizedChar)
                originalIndices.append(index)
            }
            index = transcribedText.index(after: index)
        }

        guard let anchorEnd = bestMatchEnd(of: normalizedAnchor, in: normalizedChars) else {
            AppLogger.shared.log(.warning, "Voice calibration strip: anchor phrase not found, returning unstripped")
            return transcribedText
        }

        // anchorEnd is the index (in normalized-space) just past the last matched
        // character. Cut just past it in original-space, then skip any trailing
        // whitespace/punctuation so the result doesn't start with a stray separator.
        var cutIndex = anchorEnd < originalIndices.count
            ? originalIndices[anchorEnd]
            : transcribedText.endIndex
        while cutIndex < transcribedText.endIndex,
              transcribedText[cutIndex].isWhitespace || transcribedText[cutIndex].isPunctuation {
            cutIndex = transcribedText.index(after: cutIndex)
        }

        return String(transcribedText[cutIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the index in `haystack` (already normalized) just past the best
    /// fuzzy occurrence of `needle`, or nil if nothing clears the similarity
    /// threshold. Scans every start position; at each, tries a few window
    /// lengths around the needle length (so insertions/deletions, not just
    /// substitutions, are absorbed) and keeps the highest-scoring end position.
    private static func bestMatchEnd(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        // Short anchors: exact match only (fuzzy would match incidental text).
        let allowFuzzy = needle.count >= minFuzzyAnchorLength

        // Window lengths to try at each start: the anchor length +/- a slack of
        // ~15% (rounded up), so a couple of inserted/dropped chars still align.
        let slack = allowFuzzy ? max(1, needle.count * 15 / 100) : 0
        let minLen = max(1, needle.count - slack)
        let maxLen = needle.count + slack

        // Accept threshold; a fuzzy match must clear this, an exact one is 1.0.
        // Scanning left-to-right and using a strict `>` keeps the LEFTMOST of any
        // equally-good matches (the calibration anchor, not a recurrence in real
        // dictation).
        let acceptThreshold = allowFuzzy ? minSimilarity : 1.0
        var bestScore = 0.0
        var bestEnd: Int?

        var start = 0
        while start < haystack.count {
            let maxEnd = min(haystack.count, start + maxLen)
            var windowEnd = start + minLen
            while windowEnd <= maxEnd {
                let window = Array(haystack[start..<windowEnd])
                let distance = editDistance(needle, window)
                // Normalize against the anchor length: a fixed number of errors
                // is more forgivable the longer the anchor.
                let similarity = 1.0 - Double(distance) / Double(needle.count)
                if similarity >= acceptThreshold && similarity > bestScore {
                    bestScore = similarity
                    bestEnd = windowEnd
                    if similarity == 1.0 { return windowEnd }  // exact — can't beat it
                }
                windowEnd += 1
            }
            start += 1
        }
        return bestEnd
    }

    /// Classic Levenshtein edit distance between two character arrays.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previousRow = Array(0...rhs.count)
        var currentRow = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            currentRow[0] = i
            for j in 1...rhs.count {
                let substitutionCost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                currentRow[j] = min(
                    previousRow[j] + 1,          // deletion
                    currentRow[j - 1] + 1,       // insertion
                    previousRow[j - 1] + substitutionCost  // substitution
                )
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[rhs.count]
    }

    private static func normalize(_ string: String) -> [Character] {
        string.compactMap(normalize)
    }

    /// Lowercases and keeps only letters/digits; drops punctuation and
    /// whitespace entirely so spacing/punctuation differences don't break the
    /// match.
    private static func normalize(_ char: Character) -> Character? {
        guard char.isLetter || char.isNumber else { return nil }
        return Character(char.lowercased())
    }
}
