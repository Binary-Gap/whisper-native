import Foundation

/// Cloud engine: sends the finished recording to Gemini's
/// `gemini-3.5-transcribe` model through the Interactions API and runs the text
/// through the same post-processing as Parakeet. Audio goes inline as base64
/// (no Files API), so recordings are capped at the 20 MB inline request limit
/// (~7 min of 16 kHz mono 16-bit WAV). `store: false` keeps Google from
/// retaining the interaction server-side.
public actor GeminiBackend: TranscriptionBackend {
    public static let shared = GeminiBackend()

    public static let modelID = "gemini-3.5-transcribe"
    public static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    // Inline requests max out at 20 MB; leave headroom for the JSON envelope.
    static let maxRequestBytes = 19 * 1024 * 1024

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?
    private let vocabularyProvider: @Sendable (Language) -> [String]

    /// `vocabularyProvider` runs once per request with the selected language,
    /// so vocabulary file edits apply to the next dictation.
    public init(
        session: URLSession? = nil,
        apiKeyProvider: @escaping @Sendable () -> String? = { GeminiAPIKeyStore.resolvedKey },
        vocabularyProvider: @escaping @Sendable (Language) -> [String] = { WordsFile.vocabulary(for: $0) }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
        self.apiKeyProvider = apiKeyProvider
        self.vocabularyProvider = vocabularyProvider
    }

    public func transcribe(audioFile: URL, config: Config) async throws -> TranscriptionResult {
        let startTime = Date()
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw AppError.geminiAPIKeyMissing
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFile)
        } catch {
            throw AppError.transcriptionFailed("Failed to read audio file: \(error.localizedDescription)")
        }

        let vocabulary = vocabularyProvider(config.selectedLanguage)
        let body = try Self.makeRequestBody(audio: audioData, language: config.selectedLanguage, vocabulary: vocabulary)
        guard body.count <= Self.maxRequestBytes else {
            throw AppError.transcriptionFailed("Recording too long for Gemini inline upload (max ~7 min)")
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.transcriptionFailed("Gemini request failed: \(error.localizedDescription)")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.transcriptionFailed("Invalid HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            let message = Self.errorMessage(from: data, statusCode: httpResponse.statusCode)
            AppLogger.shared.log(.error, "Gemini returned \(httpResponse.statusCode): \(message)")
            throw AppError.transcriptionFailed("Gemini returned \(httpResponse.statusCode): \(message)")
        }

        let text = Self.postProcess(try Self.parseTranscript(from: data), config: config)
        guard !text.isEmpty else { throw AppError.transcriptionEmpty }

        let durationSeconds = Date().timeIntervalSince(startTime)
        AppLogger.shared.log(
            .info,
            "Transcribe done: backend=gemini language=\(config.selectedLanguage.rawValue) "
                + "audioBytes=\(audioData.count) vocabularyTerms=\(vocabulary.count) "
                + "tookSeconds=\(String(format: "%.2f", durationSeconds))"
        )
        // The API reports no detected language; keep the configured one.
        return TranscriptionResult(
            text: text,
            language: config.selectedLanguage,
            durationSeconds: durationSeconds,
            audioFilePath: audioFile
        )
    }

    /// Filler removal, cleanup, then the "Sentence per line" / "Wrap lines"
    /// settings. Shared with the Gemini Live engine.
    public static func postProcess(_ rawText: String, config: Config) -> String {
        var text = WhisperClient.cleanTranscriptText(
            FillerRemover.removeFillers(from: rawText, language: config.selectedLanguage)
        )
        if config.sentencePerLine {
            text = WhisperClient.splitSentencesOntoLines(text)
        }
        if config.lineWrapEnabled {
            text = LineWrapper.wrap(text, width: min(100, max(20, config.lineWrapWidth)))
        }
        return text
    }

    /// Gemini has no timestamped-segment path wired; returns no segments.
    public func transcribeWithSegments(audioFile: URL, config: Config) async throws -> (result: TranscriptionResult, segments: [TranscriptionSegment]) {
        (try await transcribe(audioFile: audioFile, config: config), [])
    }

    /// True when a key resolves. No network ping: the key's per-minute rate
    /// limit is kept for dictation.
    public func isAvailable() async -> Bool {
        guard let key = apiKeyProvider() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Request / response encoding

    private struct InteractionRequest: Encodable {
        struct AudioInput: Encodable {
            let type = "audio"
            let mimeType = "audio/wav"
            let data: String

            enum CodingKeys: String, CodingKey {
                case type
                case mimeType = "mime_type"
                case data
            }
        }

        struct GenerationConfig: Encodable {
            struct TranscriptionConfig: Encodable {
                let languageCodes: [String]
                /// Nil when empty, so the field is left out.
                let customVocabulary: [String]?

                enum CodingKeys: String, CodingKey {
                    case languageCodes = "language_codes"
                    case customVocabulary = "custom_vocabulary"
                }
            }

            let transcriptionConfig: TranscriptionConfig

            enum CodingKeys: String, CodingKey {
                case transcriptionConfig = "transcription_config"
            }
        }

        let model: String
        let store: Bool
        let input: [AudioInput]
        let generationConfig: GenerationConfig

        enum CodingKeys: String, CodingKey {
            case model
            case store
            case input
            case generationConfig = "generation_config"
        }
    }

    /// JSON body for `POST /v1beta/interactions`. Auto sends no language hint
    /// (Gemini auto-detects); a fixed language goes as its whisper code, which
    /// the API accepts as a hint. A non-empty vocabulary goes as
    /// `custom_vocabulary`; an empty one leaves the field out.
    static func makeRequestBody(audio: Data, language: Language, vocabulary: [String] = []) throws -> Data {
        let request = InteractionRequest(
            model: modelID,
            store: false,
            input: [.init(data: audio.base64EncodedString())],
            generationConfig: .init(transcriptionConfig: .init(
                languageCodes: language == .auto ? [] : [language.rawValue],
                customVocabulary: vocabulary.isEmpty ? nil : vocabulary
            ))
        )
        return try JSONEncoder().encode(request)
    }

    private struct InteractionResponse: Decodable {
        struct Step: Decodable {
            struct Content: Decodable {
                let type: String?
                let text: String?
            }

            let type: String?
            let content: [Content]?
        }

        let steps: [Step]?
    }

    /// Joins the text of every `text` content item across `model_output` steps.
    static func parseTranscript(from data: Data) throws -> String {
        let response: InteractionResponse
        do {
            response = try JSONDecoder().decode(InteractionResponse.self, from: data)
        } catch {
            throw AppError.transcriptionFailed("Failed to decode Gemini response: \(error.localizedDescription)")
        }
        let text = (response.steps ?? [])
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError.transcriptionFailed("Gemini returned no transcript") }
        return text
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String?
        }

        let error: Detail?
    }

    /// Error text from a non-200 body. Gemini answers with either an object
    /// (`{"error":{...}}`) or a one-element array of it; anything else falls
    /// back to the raw body, truncated.
    static func errorMessage(from data: Data, statusCode: Int) -> String {
        let decoder = JSONDecoder()
        if let message = (try? decoder.decode(ErrorEnvelope.self, from: data))?.error?.message {
            return message
        }
        if let message = (try? decoder.decode([ErrorEnvelope].self, from: data))?.first?.error?.message {
            return message
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return HTTPURLResponse.localizedString(forStatusCode: statusCode) }
        return raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
    }
}
