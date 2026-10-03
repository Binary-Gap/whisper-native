import Foundation

/// Wire format of Gemini Live (`BidiGenerateContent`) transcription sessions
/// with manual activity detection: client messages as JSON text frames, server
/// messages decoded into `GeminiLiveEvent`s, and the whisper-code to BCP-47
/// language mapping. Pure functions, no I/O.
public enum GeminiLiveProtocol {
    /// Raw 16 kHz mono 16-bit little-endian PCM, as the recorder produces it.
    public static let audioMimeType = "audio/pcm;rate=16000"
    /// 100 ms of audio at 16 kHz mono 16-bit, the chunk size the docs recommend.
    public static let chunkBytes = 3200
    public static let bytesPerSecond = 32000

    // MARK: - Client messages

    private struct SetupMessage: Encodable {
        struct Setup: Encodable {
            struct GenerationConfig: Encodable {
                let responseModalities = ["TEXT"]
            }

            struct RealtimeInputConfig: Encodable {
                struct AutomaticActivityDetection: Encodable {
                    let disabled = true
                }

                let automaticActivityDetection = AutomaticActivityDetection()
            }

            struct InputAudioTranscription: Encodable {
                let languageCodes: [String]
                let mode: String
            }

            let model: String
            let generationConfig = GenerationConfig()
            let realtimeInputConfig = RealtimeInputConfig()
            let inputAudioTranscription: InputAudioTranscription
        }

        let setup: Setup
    }

    private struct RealtimeInputMessage: Encodable {
        struct RealtimeInput: Encodable {
            struct Audio: Encodable {
                let data: String
                let mimeType: String
            }

            struct Empty: Encodable {}

            var audio: Audio?
            var activityStart: Empty?
            var activityEnd: Empty?
        }

        let realtimeInput: RealtimeInput
    }

    /// First message on a new socket: model, text-only output, manual activity
    /// detection (the app marks the turn with activityStart/activityEnd) and the
    /// transcription config.
    public static func setupMessage(model: String, languageCodes: [String], mode: GeminiLiveMode) -> String {
        encode(SetupMessage(setup: .init(
            model: "models/\(model)",
            inputAudioTranscription: .init(languageCodes: languageCodes, mode: mode.rawValue)
        )))
    }

    public static func activityStartMessage() -> String {
        encode(RealtimeInputMessage(realtimeInput: .init(activityStart: .init())))
    }

    public static func activityEndMessage() -> String {
        encode(RealtimeInputMessage(realtimeInput: .init(activityEnd: .init())))
    }

    public static func audioMessage(pcm: Data) -> String {
        encode(RealtimeInputMessage(realtimeInput: .init(
            audio: .init(data: pcm.base64EncodedString(), mimeType: audioMimeType)
        )))
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The message types above hold only strings, bools and arrays: encoding can't fail.
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Server messages

    private struct ServerMessage: Decodable {
        struct Empty: Decodable {}

        struct Transcription: Decodable {
            let text: String?
        }

        struct ServerContent: Decodable {
            let interimInputTranscription: Transcription?
            let inputTranscription: Transcription?
            let generationComplete: Bool?
            let turnComplete: Bool?
        }

        struct ErrorDetail: Decodable {
            let message: String?
        }

        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let responseTokenCount: Int?
            let thoughtsTokenCount: Int?
            let totalTokenCount: Int?
        }

        let setupComplete: Empty?
        let serverContent: ServerContent?
        let usageMetadata: UsageMetadata?
        let goAway: Empty?
        let error: ErrorDetail?
    }

    /// Top-level message keys the decoder above handles; anything else is
    /// logged once per session in Debug builds.
    static let knownMessageKeys: Set<String> = ["setupComplete", "serverContent", "usageMetadata", "goAway", "error"]

    /// Top-level keys of one server message, for spotting fields the decoder skips.
    public static func unknownMessageKeys(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.filter { !knownMessageKeys.contains($0) }.sorted()
    }

    /// Events in one server message, in handling order (a single message can
    /// carry a final transcript and generationComplete together). Unknown
    /// shapes decode to no events.
    public static func events(from data: Data) -> [GeminiLiveEvent] {
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return [] }
        var events: [GeminiLiveEvent] = []
        if message.setupComplete != nil { events.append(.setupComplete) }
        if let content = message.serverContent {
            if let text = content.interimInputTranscription?.text { events.append(.interim(text)) }
            if let text = content.inputTranscription?.text { events.append(.final(text)) }
            if content.generationComplete == true { events.append(.generationComplete) }
            if content.turnComplete == true { events.append(.turnComplete) }
        }
        if let usage = message.usageMetadata {
            events.append(.usage(GeminiLiveUsage(
                promptTokens: usage.promptTokenCount ?? 0,
                responseTokens: usage.responseTokenCount ?? 0,
                thoughtsTokens: usage.thoughtsTokenCount ?? 0,
                totalTokens: usage.totalTokenCount ?? 0
            )))
        }
        if message.goAway != nil { events.append(.goAway) }
        if let error = message.error { events.append(.error(error.message ?? "unknown error")) }
        return events
    }

    /// Joins final transcript segments, adding a space between two segments
    /// only when neither side already has whitespace at the seam.
    public static func joinSegments(_ segments: [String]) -> String {
        segments.reduce(into: "") { joined, segment in
            guard !segment.isEmpty else { return }
            if let last = joined.last, !last.isWhitespace, let first = segment.first, !first.isWhitespace {
                joined += " "
            }
            joined += segment
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Language

    /// BCP-47 codes Gemini 3.5 Transcribe Live supports, keyed by whisper code.
    /// The first entry is the default; the others are regional variants picked
    /// by the system region. Whisper languages missing from Gemini's table are
    /// absent (they get auto-detect).
    static let supportedLanguageCodes: [String: [String]] = [
        "af": ["af-ZA"], "am": ["am-ET"], "ar": ["ar-EG"], "as": ["as-IN"], "az": ["az-AZ"],
        "be": ["be-BY"], "bg": ["bg-BG"], "bn": ["bn-BD", "bn-IN"], "bs": ["bs-BA"], "ca": ["ca-ES"],
        "cs": ["cs-CZ"], "da": ["da-DK"], "de": ["de-DE"], "el": ["el-GR"],
        "en": ["en-US", "en-GB", "en-IN"], "es": ["es-419", "es-US"], "et": ["et-EE"], "fa": ["fa-IR"],
        "fi": ["fi-FI"], "fr": ["fr-FR"], "gl": ["gl-ES"], "gu": ["gu-IN"], "ha": ["ha-NG"],
        "he": ["he-IL"], "hi": ["hi-IN"], "hr": ["hr-HR"], "hu": ["hu-HU"], "hy": ["hy-AM"],
        "id": ["id-ID"], "is": ["is-IS"], "it": ["it-IT"], "ja": ["ja-JP"], "jw": ["jv-ID"],
        "ka": ["ka-GE"], "kk": ["kk-KZ"], "km": ["km-KH"], "kn": ["kn-IN"], "ko": ["ko-KR"],
        "ln": ["ln-CD"], "lt": ["lt-LT"], "lv": ["lv-LV"], "mk": ["mk-MK"], "ml": ["ml-IN"],
        "mn": ["mn-MN"], "mr": ["mr-IN"], "ms": ["ms-MY"], "mt": ["mt-MT"], "my": ["my-MM"],
        "ne": ["ne-NP"], "nl": ["nl-NL"], "no": ["nb-NO"], "pa": ["pa-IN"], "pl": ["pl-PL"],
        "pt": ["pt-BR", "pt-PT"], "ro": ["ro-RO"], "ru": ["ru-RU"], "sd": ["sd-Arab-IN"],
        "sk": ["sk-SK"], "sl": ["sl-SI"], "sr": ["sr-RS"], "sv": ["sv-SE"], "sw": ["sw-KE"],
        "te": ["te-IN"], "tg": ["tg-TJ"], "th": ["th-TH"], "tl": ["fil-PH"], "tr": ["tr-TR"],
        "uk": ["uk-UA"], "uz": ["uz-UZ"], "vi": ["vi-VN"], "yue": ["yue-Hant-HK"],
        "zh": ["cmn-Hans-CN"],
    ]

    /// `languageCodes` for the setup message. Auto sends none (Gemini
    /// auto-detects); a fixed language sends its BCP-47 hint, preferring the
    /// variant for the system region (pt + BR -> pt-BR, pt + PT -> pt-PT) and
    /// otherwise the default variant. Languages Gemini doesn't list send none.
    public static func languageCodes(
        for language: Language,
        regionCode: String? = Locale.current.region?.identifier
    ) -> [String] {
        guard language != .auto, let variants = supportedLanguageCodes[language.rawValue] else { return [] }
        if let regionCode, let regional = variants.first(where: { $0.hasSuffix("-\(regionCode)") }) {
            return [regional]
        }
        return [variants[0]]
    }
}

/// One thing the server told a Gemini Live session.
public enum GeminiLiveEvent: Equatable, Sendable {
    case setupComplete
    /// Speculative hypothesis for the speech since the last final segment.
    case interim(String)
    /// Authoritative transcript of one speech segment.
    case final(String)
    case generationComplete
    case turnComplete
    /// Token counts the server billed for the session so far.
    case usage(GeminiLiveUsage)
    /// The server will close the connection soon.
    case goAway
    case error(String)
}

/// Token counts from a Live `usageMetadata` message, with a cost estimate at
/// the paid-tier list price of gemini-3.5-transcribe-live.
public struct GeminiLiveUsage: Equatable, Sendable {
    public var promptTokens: Int
    public var responseTokens: Int
    public var thoughtsTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int, responseTokens: Int, thoughtsTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.thoughtsTokens = thoughtsTokens
        self.totalTokens = totalTokens
    }

    public var estimatedDollars: Double {
        (Double(promptTokens) * GeminiPricing.live.inputDollarsPerMillionTokens
            + Double(responseTokens + thoughtsTokens) * GeminiPricing.live.outputDollarsPerMillionTokens) / 1_000_000
    }
}
