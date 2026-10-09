import XCTest
@testable import WhisperNativeCore

final class GeminiBackendTests: XCTestCase {
    private var scratchDirectory: URL?

    override func tearDownWithError() throws {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    // MARK: - Request body

    private func requestJSON(audio: Data, language: Language, vocabulary: [String] = []) throws -> [String: Any] {
        let body = try GeminiBackend.makeRequestBody(audio: audio, language: language, vocabulary: vocabulary)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func transcriptionConfig(in json: [String: Any]) throws -> [String: Any] {
        let generationConfig = try XCTUnwrap(json["generation_config"] as? [String: Any])
        return try XCTUnwrap(generationConfig["transcription_config"] as? [String: Any])
    }

    private func languageCodes(in json: [String: Any]) throws -> [String] {
        let generationConfig = try XCTUnwrap(json["generation_config"] as? [String: Any])
        let transcriptionConfig = try XCTUnwrap(generationConfig["transcription_config"] as? [String: Any])
        return try XCTUnwrap(transcriptionConfig["language_codes"] as? [String])
    }

    func testRequestBodyCarriesModelStoreAndInlineAudio() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x10])
        let json = try requestJSON(audio: audio, language: .auto)

        XCTAssertEqual(json["model"] as? String, "gemini-3.5-transcribe")
        XCTAssertEqual(json["store"] as? Bool, false)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "audio")
        XCTAssertEqual(input[0]["mime_type"] as? String, "audio/wav")
        let base64 = try XCTUnwrap(input[0]["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64), audio)
    }

    func testAutoLanguageSendsNoHint() throws {
        XCTAssertEqual(try languageCodes(in: requestJSON(audio: Data([1]), language: .auto)), [])
    }

    func testFixedLanguageSendsItsCode() throws {
        XCTAssertEqual(try languageCodes(in: requestJSON(audio: Data([1]), language: .portuguese)), ["pt"])
    }

    func testVocabularyGoesAsCustomVocabulary() throws {
        let json = try requestJSON(audio: Data([1]), language: .auto, vocabulary: ["Kubernetes", "BigQuery"])
        XCTAssertEqual(try transcriptionConfig(in: json)["custom_vocabulary"] as? [String], ["Kubernetes", "BigQuery"])
    }

    func testEmptyVocabularyOmitsTheField() throws {
        let config = try transcriptionConfig(in: requestJSON(audio: Data([1]), language: .portuguese))
        XCTAssertNil(config["custom_vocabulary"])
        XCTAssertEqual(config["language_codes"] as? [String], ["pt"])
    }

    // MARK: - Response parsing

    func testParsesTranscriptFromModelOutputStep() throws {
        let body = Data("""
        {"id":null,"status":"completed","object":"interaction","model":"gemini-3.5-transcribe",
         "steps":[{"type":"model_output","content":[{"type":"text","text":"Testing the Gemini transcription backend."}]}],
         "usage":{"total_tokens":42}}
        """.utf8)
        XCTAssertEqual(try GeminiBackend.parseTranscript(from: body), "Testing the Gemini transcription backend.")
    }

    func testConcatenatesTextItemsAndSkipsOtherSteps() throws {
        let body = Data("""
        {"steps":[
          {"type":"user_input","content":[{"type":"text","text":"ignored"}]},
          {"type":"model_output","content":[{"type":"text","text":"Hello "},{"type":"audio"},{"type":"text","text":"world."}]}
        ]}
        """.utf8)
        XCTAssertEqual(try GeminiBackend.parseTranscript(from: body), "Hello world.")
    }

    func testMissingStepsThrows() {
        XCTAssertThrowsError(try GeminiBackend.parseTranscript(from: Data(#"{"status":"completed"}"#.utf8)))
    }

    // MARK: - Error parsing

    func testErrorMessageFromObjectShape() {
        let body = Data(#"{"error":{"message":"Rate limit exceeded for model gemini-3.5-transcribe","code":"too_many_requests"}}"#.utf8)
        XCTAssertEqual(
            GeminiBackend.errorMessage(from: body, statusCode: 429),
            "Rate limit exceeded for model gemini-3.5-transcribe"
        )
    }

    func testErrorMessageFromArrayShape() {
        let body = Data(#"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}]"#.utf8)
        XCTAssertEqual(
            GeminiBackend.errorMessage(from: body, statusCode: 400),
            "API key not valid. Please pass a valid API key."
        )
    }

    func testErrorMessageFallsBackToTruncatedRawBody() {
        let garbage = String(repeating: "x", count: 500)
        let message = GeminiBackend.errorMessage(from: Data(garbage.utf8), statusCode: 502)
        XCTAssertTrue(message.hasPrefix("xxx"))
        XCTAssertLessThan(message.count, 310)
    }

    // MARK: - Key handling

    func testMissingKeyThrowsWithoutNetwork() async throws {
        let backend = GeminiBackend(apiKeyProvider: { nil })
        let isAvailable = await backend.isAvailable()
        XCTAssertFalse(isAvailable)
        do {
            _ = try await backend.transcribe(audioFile: URL(fileURLWithPath: "/nonexistent.wav"), config: Config())
            XCTFail("Expected geminiAPIKeyMissing")
        } catch AppError.geminiAPIKeyMissing {
            // expected
        }
    }

    // MARK: - Live API

    /// Real round trip through GeminiBackend. Billed: runs only with
    /// `BilledGeminiTests.apiKey()` opted in. One request, the key is rate
    /// limited per minute.
    func testLiveTranscriptionOfSpokenWav() async throws {
        let apiKey = try BilledGeminiTests.apiKey()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiBackendTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectory = directory
        let aiffURL = directory.appendingPathComponent("speech.aiff")
        let wavURL = directory.appendingPathComponent("speech.wav")
        try runTool("/usr/bin/say", ["-o", aiffURL.path, "The quick brown fox jumps over the lazy dog."])
        try runTool("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiffURL.path, wavURL.path])

        var config = Config()
        config.selectedLanguage = .auto
        config.sentencePerLine = false
        config.lineWrapEnabled = false
        // Real terms exercise the custom_vocabulary request path end to end.
        let backend = GeminiBackend(apiKeyProvider: { apiKey }, vocabularyProvider: { _ in ["BigQuery", "Kubernetes"] })
        let result = try await backend.transcribe(audioFile: wavURL, config: config)

        print("Gemini live transcript: \"\(result.text)\" tookSeconds=\(String(format: "%.2f", result.durationSeconds))")
        XCTAssertTrue(result.text.lowercased().contains("quick brown fox"), "Unexpected transcript: \(result.text)")
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) failed")
    }
}

/// Gate for the tests that call the real Gemini API. A key alone never runs
/// them: they also need GEMINI_BILLED_TESTS=1, so a key exported for other
/// reasons (fnox, a shell profile) cannot bill a routine test run. Pass both to
/// xcodebuild with the TEST_RUNNER_ prefix.
enum BilledGeminiTests {
    static func apiKey() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["GEMINI_BILLED_TESTS"] == "1", "Billed Gemini test: set GEMINI_BILLED_TESTS=1 to run")
        let apiKey = environment["GEMINI_API_KEY"] ?? ""
        try XCTSkipIf(apiKey.isEmpty, "GEMINI_API_KEY not set")
        return apiKey
    }
}
