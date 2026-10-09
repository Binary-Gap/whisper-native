import Foundation

public struct TranscriptionResult: Sendable {
    public let text: String
    public let language: Language
    public let durationSeconds: Double
    public let audioFilePath: URL

    public init(text: String, language: Language, durationSeconds: Double, audioFilePath: URL) {
        self.text = text
        self.language = language
        self.durationSeconds = durationSeconds
        self.audioFilePath = audioFilePath
    }
}

/// One timestamped transcript segment as returned by whisper's verbose_json.
/// `start`/`end` are in seconds relative to the start of the submitted audio.
public struct TranscriptionSegment: Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A transcription language: one of whisper.cpp's language codes (its `g_lang`
/// table) or `auto`. The raw value is the whisper code, so persisted configs and
/// history entries round-trip unchanged; unknown decoded codes fall back to `.auto`.
public struct Language: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String

    /// Fails for codes outside whisper's language table (and not "auto").
    public init?(rawValue: String) {
        guard rawValue == Self.autoCode || Self.whisperCodes.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(knownCode: String) {
        rawValue = knownCode
    }

    public static let auto = Language(knownCode: autoCode)
    public static let english = Language(knownCode: "en")
    public static let portuguese = Language(knownCode: "pt")

    private static let autoCode = "auto"

    /// whisper.cpp's `g_lang` codes, in its table order.
    static let whisperCodes: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar",
        "sv", "it", "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu",
        "ta", "no", "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa",
        "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn",
        "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
        "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn",
        "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw",
        "su", "yue",
    ]

    /// Every selectable language: auto first, then the rest sorted by display name.
    public static let all: [Language] = [.auto] + whisperCodes
        .map { Language(knownCode: $0) }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

    /// The macOS system language, when whisper supports it. macOS reports
    /// Norwegian Bokmal as "nb", Javanese as "jv" and Filipino as "fil"; whisper
    /// uses "no", "jw" and "tl".
    public static func systemLanguage(code: String? = Locale.current.language.languageCode?.identifier) -> Language? {
        guard let code else { return nil }
        let aliases = ["nb": "no", "jv": "jw", "fil": "tl"]
        return Language(rawValue: aliases[code] ?? code)
    }

    /// Next language for the cycle hotkey: the entry after `current` in `cycle`
    /// (wrapping), or the first entry when `current` isn't in it. An empty cycle
    /// keeps `current`.
    public static func next(after current: Language, in cycle: [Language]) -> Language {
        guard let first = cycle.first else { return current }
        guard let index = cycle.firstIndex(of: current) else { return first }
        return cycle[(index + 1) % cycle.count]
    }

    /// Whether `code`'s language is written in Latin script (per its likely
    /// full locale, e.g. "pt" -> "pt-Latn-BR").
    public static func isLatinScript(code: String) -> Bool {
        let maximal = Locale.Language(identifier: code).maximalIdentifier
        return Locale.Language(identifier: maximal).script?.identifier == "Latn"
    }

    public var id: String { rawValue }

    /// Short uppercase code shown in the menu bar and the language HUD.
    public var displayCode: String { rawValue.uppercased() }

    /// Localized language name ("Auto detect" for auto), shown in Settings and
    /// under the code in the language HUD.
    public var displayName: String {
        if self == .auto { return "Auto detect" }
        // whisper's Javanese code is "jw"; the ISO code Locale knows is "jv".
        let isoCode = rawValue == "jw" ? "jv" : rawValue
        guard let name = Locale.current.localizedString(forLanguageCode: isoCode) else { return displayCode }
        // Some locales (pt, es, fr) name languages in lowercase.
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// English language name whatever the system language ("Auto detect" for
    /// auto), used where a name must stay stable across locales, e.g. the
    /// words file's language keys.
    public var englishName: String {
        if self == .auto { return "Auto detect" }
        let isoCode = rawValue == "jw" ? "jv" : rawValue
        return Locale(identifier: "en").localizedString(forLanguageCode: isoCode) ?? displayCode
    }

    public init(from decoder: Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        self = Language(rawValue: code) ?? .auto
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A CoreAudio input-capable device, as listed for the Settings microphone picker.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}
