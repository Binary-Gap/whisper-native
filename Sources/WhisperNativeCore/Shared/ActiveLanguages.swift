import Foundation

/// Pure logic behind the app's active languages (`Config.activeLanguages`): the
/// languages the user dictates in, offered by the transcription language picker
/// and stepped through by the cycle hotkey, in the order they were added.
public enum ActiveLanguages {

    /// Languages that can still be added for `query`: every language in `all`
    /// that isn't active and whose display name or code contains the query
    /// (case and diacritic insensitive). Exact code matches come first, then
    /// name/code prefix matches, then the rest, each group in `all`'s order.
    /// A blank query matches nothing.
    public static func addable(
        matching query: String,
        active: [Language],
        all: [Language] = Language.all,
        name: (Language) -> String = { $0.displayName }
    ) -> [Language] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let activeSet = Set(active)

        var exactCode: [Language] = []
        var prefix: [Language] = []
        var contains: [Language] = []
        for language in all where !activeSet.contains(language) {
            let code = fold(language.rawValue)
            let languageName = fold(name(language))
            if code == needle {
                exactCode.append(language)
            } else if languageName.hasPrefix(needle) || code.hasPrefix(needle) {
                prefix.append(language)
            } else if languageName.contains(needle) || code.contains(needle) {
                contains.append(language)
            }
        }
        return exactCode + prefix + contains
    }

    /// `active` with `language` appended, unchanged when it's already active.
    public static func adding(_ language: Language, to active: [Language]) -> [Language] {
        active.contains(language) ? active : active + [language]
    }

    /// Removes `language` from `active`. The last active language stays (the
    /// app always needs one); removing the selected language moves the
    /// selection to the first remaining active language.
    public static func removing(
        _ language: Language,
        from active: [Language],
        selected: Language
    ) -> (active: [Language], selected: Language) {
        let remaining = active.filter { $0 != language }
        guard let first = remaining.first else { return (active, selected) }
        return (remaining, remaining.contains(selected) ? selected : first)
    }

    /// Whether `language` may be removed from `active` (never the last one).
    public static func canRemove(_ language: Language, from active: [Language]) -> Bool {
        active.contains(language) && active.count > 1
    }

    /// Repairs a persisted list: drops duplicates (keeping the first) and
    /// appends `selected` when it isn't active, so the picker always shows the
    /// current language and the list is never empty.
    public static func normalized(_ active: [Language], selected: Language) -> [Language] {
        var seen = Set<Language>()
        let unique = active.filter { seen.insert($0).inserted }
        return unique.contains(selected) ? unique : unique + [selected]
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
