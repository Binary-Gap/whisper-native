import Foundation

public actor WhisperClient: TranscriptionBackend {
    private let serverBaseURL: URL
    private let inferenceURL: URL
    private let healthURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let vocabularyProvider: @Sendable (Language) -> [String]

    /// `vocabularyProvider` runs once per request with the selected language
    /// (only while `Config.whisperUsesVocabulary` is on), so words file edits
    /// apply to the next dictation.
    public init(
        serverBaseURL: URL = Constants.serverBaseURL,
        vocabularyProvider: @escaping @Sendable (Language) -> [String] = { WordsFile.load(for: $0).vocabulary }
    ) {
        self.vocabularyProvider = vocabularyProvider
        self.serverBaseURL = serverBaseURL
        self.inferenceURL = serverBaseURL.appendingPathComponent("inference")
        self.healthURL = serverBaseURL.appendingPathComponent("health")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func transcribe(audioFile: URL, config: Config) async throws -> TranscriptionResult {
        try await runInference(audioFile: audioFile, config: config, verbose: false).result
    }

    public func transcribeWithSegments(audioFile: URL, config: Config) async throws -> (result: TranscriptionResult, segments: [TranscriptionSegment]) {
        try await runInference(audioFile: audioFile, config: config, verbose: true)
    }

    /// Shared inference request. `verbose == true` requests SRT so the response
    /// carries per-segment timestamps (parsed into segments); otherwise the
    /// lighter json form that returns only the flat text.
    private func runInference(audioFile: URL, config: Config, verbose: Bool) async throws -> (result: TranscriptionResult, segments: [TranscriptionSegment]) {
        let startTime = Date()

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFile)
        } catch {
            throw AppError.transcriptionFailed("Failed to read audio file: \(error.localizedDescription)")
        }

        var form = MultipartFormData()
        form.addFileField(
            name: "file",
            filename: audioFile.lastPathComponent,
            mimeType: "audio/wav",
            data: audioData
        )

        // Language: pass the whisper code ("en", "pt", ..., "auto")
        form.addTextField(name: "language", value: config.selectedLanguage.rawValue)

        if config.translateToEnglish {
            form.addTextField(name: "translate", value: "true")
        }

        let prompt = resolvedPrompt(config: config)
        let promptText = prompt.text
        if !promptText.isEmpty {
            form.addTextField(name: "prompt", value: promptText)
        }

        // SRT for the calibration split (plain-text body with per-segment
        // timestamps); plain json otherwise (flat text only).
        let responseFormat = verbose ? "srt" : "json"
        form.addTextField(name: "response_format", value: responseFormat)

        // Cap segment length and break on word boundaries so the transcript
        // comes back wrapped to the configured width.
        if config.lineWrapEnabled {
            let width = min(100, max(20, config.lineWrapWidth))
            form.addTextField(name: "max_len", value: String(width))
            form.addTextField(name: "split_on_word", value: "true")
        }

        AppLogger.shared.log(
            .info,
            "Transcribe request: file=\(audioFile.path) "
                + "language=\(config.selectedLanguage.rawValue) "
                + "translate=\(config.translateToEnglish) "
                + "model=\(config.selectedModelName) "
                + "responseFormat=\(responseFormat) "
                + "vadEnabled=\(config.vadModelPath != nil) "
                + "audioBytes=\(audioData.count) "
                + "vocabularyTerms=\(prompt.includedTerms.count) "
                + "prompt=\"\(promptText)\""
        )

        let body = form.finalize()

        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.transcriptionFailed("HTTP request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.transcriptionFailed("Invalid HTTP response")
        }

        // 503 while loading model
        if httpResponse.statusCode == 503 {
            // Try to decode status message
            if let decoded = try? decoder.decode(ServerStatusResponse.self, from: data),
               decoded.status == "loading model" {
                throw AppError.serverUnhealthy("loading model")
            }
            throw AppError.serverUnhealthy("Service unavailable (503)")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<undecodable>"
            throw AppError.transcriptionFailed("Server returned \(httpResponse.statusCode): \(body)")
        }

        let rawText: String
        let detectedLanguageCode: String?
        let segments: [TranscriptionSegment]

        if verbose {
            // Plain-text SRT body: parse blocks into timestamped segments and
            // reconstruct the flat transcript from them. SRT carries no language
            // field, so language falls back to the configured one below.
            guard let srt = String(data: data, encoding: .utf8) else {
                throw AppError.transcriptionFailed("Failed to decode SRT response as UTF-8")
            }
            segments = SRTParser.parse(srt)
            rawText = SRTParser.fullText(from: segments)
            detectedLanguageCode = nil
        } else {
            let inferenceResponse: InferenceResponse
            do {
                inferenceResponse = try decoder.decode(InferenceResponse.self, from: data)
            } catch {
                throw AppError.transcriptionFailed("Failed to decode response: \(error.localizedDescription)")
            }
            rawText = inferenceResponse.text
            detectedLanguageCode = inferenceResponse.language
            segments = []
        }

        var text = Self.cleanTranscriptText(rawText)
        if config.sentencePerLine {
            text = Self.splitSentencesOntoLines(text)
        }
        guard !text.isEmpty else {
            throw AppError.transcriptionEmpty
        }

        let durationSeconds = Date().timeIntervalSince(startTime)
        let detectedLanguage = config.selectedLanguage == .auto
            ? (detectedLanguageCode.flatMap { Language(rawValue: $0) } ?? .auto)
            : config.selectedLanguage

        let result = TranscriptionResult(
            text: text,
            language: detectedLanguage,
            durationSeconds: durationSeconds,
            audioFilePath: audioFile
        )
        return (result, segments)
    }

    /// Trim leading/trailing whitespace from every line, then trim the whole
    /// blob's outer edges (max_len wrapping leaves ragged margins).
    static func cleanTranscriptText(_ raw: String) -> String {
        raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inserts a newline after each sentence-ending punctuation mark (. ! ?),
    /// optionally followed by closing quotes/brackets, when the next non-space
    /// character begins a new sentence. So every sentence starts on its own line.
    ///
    /// Abbreviations and decimals inevitably produce false breaks (whisper rarely
    /// emits either in dictation), so this stays deliberately simple: a period
    /// that is immediately followed by whitespace and then any character breaks
    /// the line. Runs of separators collapse; trailing whitespace per line is
    /// trimmed by the caller's cleanup already.
    static func splitSentencesOntoLines(_ text: String) -> String {
        let terminators: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»"]

        var result = ""
        result.reserveCapacity(text.count + 16)
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            result.append(char)

            if terminators.contains(char) {
                // Absorb any closing quotes/brackets that belong to this sentence.
                var lookahead = index + 1
                while lookahead < characters.count, closers.contains(characters[lookahead]) {
                    result.append(characters[lookahead])
                    lookahead += 1
                }
                // Require whitespace after the terminator, and at least one more
                // character to start the next sentence, before breaking.
                if lookahead < characters.count, characters[lookahead].isWhitespace {
                    var nextContent = lookahead
                    while nextContent < characters.count, characters[nextContent].isWhitespace {
                        nextContent += 1
                    }
                    if nextContent < characters.count {
                        result.append("\n")
                        index = nextContent
                        continue
                    }
                }
                index = lookahead
                continue
            }
            index += 1
        }
        return result
    }

    public func isAvailable() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let status = try? decoder.decode(ServerStatusResponse.self, from: data)
        else {
            return false
        }

        return status.status == "ok"
    }

    /// Prompt for this request (`WhisperPrompt`), with the words file read now
    /// when the vocabulary is on. Logs a warning when terms don't fit.
    private func resolvedPrompt(config: Config) -> WhisperPrompt.Built {
        let vocabulary = config.whisperUsesVocabulary ? vocabularyProvider(config.selectedLanguage) : []
        let prompt = WhisperPrompt.build(config: config, vocabulary: vocabulary)
        if let firstDropped = prompt.droppedTerms.first {
            AppLogger.shared.log(
                .warning,
                "Whisper prompt: \(prompt.includedTerms.count) of \(prompt.includedTerms.count + prompt.droppedTerms.count) vocabulary terms fit whisper's prompt limit (~\(WhisperPrompt.whisperMaxTokens) tokens), left out the rest from \"\(firstDropped)\""
            )
        }
        return prompt
    }
}

// MARK: - Response types

private struct InferenceResponse: Decodable {
    let text: String
    let language: String?
}

private struct ServerStatusResponse: Decodable {
    let status: String
}
