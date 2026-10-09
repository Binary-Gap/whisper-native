import Foundation

/// Strips hesitation sounds ("uh", "um", "hmm") that Parakeet transcribes
/// verbatim (whisper drops them on its own, having been trained on cleaned-up
/// subtitles). Only standalone words are removed, never real words like "é",
/// "ah" or "tipo".
public enum FillerRemover {
    /// Not words in English or Portuguese, safe to drop in any language.
    static let universalFillers: Set<String> = ["uh", "uhh", "uhm", "hmm", "hm", "mm", "erm", "hã", "ahn"]
    /// "um" is the Portuguese article ("a/one"), so these only go for non-Portuguese text.
    static let englishOnlyFillers: Set<String> = ["um", "umm"]

    public static func removeFillers(from text: String, language: Language) -> String {
        let isPortuguese = switch language {
        case .portuguese: true
        case .auto: looksPortuguese(text)
        default: false
        }
        let fillers = isPortuguese ? universalFillers : universalFillers.union(englishOnlyFillers)

        var kept: [String] = []
        var capitalizeNext = false
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if fillers.contains(bare) {
                // A capitalized filler started a sentence; the next kept word does now.
                if word.first?.isUppercase == true { capitalizeNext = true }
                // "hour uh. Next" keeps the sentence end the filler carried.
                if let terminator = word.last, ".!?".contains(terminator),
                   let previous = kept.last, let previousEnd = previous.last,
                   !".!?,;:".contains(previousEnd) {
                    kept[kept.count - 1] = previous + String(terminator)
                }
                continue
            }
            kept.append(capitalizeNext ? word.prefix(1).uppercased() + word.dropFirst() : word)
            capitalizeNext = false
        }
        return kept.joined(separator: " ")
    }

    // ponytail: diacritic/stopword sniff for auto mode, swap for real language ID if it misfires
    static func looksPortuguese(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains(where: { "ãõçêâáéíóúà".contains($0) }) { return true }
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["que", "não", "de", "uma", "para", "com", "eu", "isso", "você"])
    }
}
