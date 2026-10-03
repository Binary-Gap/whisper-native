import XCTest
@testable import WhisperNativeCore

final class GeminiLiveProtocolTests: XCTestCase {

    private func json(_ message: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    }

    // MARK: - Client messages

    func testSetupMessageCarriesModelManualVadLanguageAndMode() throws {
        let message = GeminiLiveProtocol.setupMessage(model: "gemini-3.5-transcribe-live", languageCodes: ["pt-BR"], mode: .smart)
        let setup = try XCTUnwrap(try json(message)["setup"] as? [String: Any])

        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        let generationConfig = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["responseModalities"] as? [String], ["TEXT"])
        let realtimeInputConfig = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        let detection = try XCTUnwrap(realtimeInputConfig["automaticActivityDetection"] as? [String: Any])
        XCTAssertEqual(detection["disabled"] as? Bool, true)
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["pt-BR"])
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
    }

    func testSetupMessageSendsEmptyLanguageCodesForAuto() throws {
        let message = GeminiLiveProtocol.setupMessage(model: "m", languageCodes: [], mode: .verbatim)
        let transcription = try XCTUnwrap((try json(message)["setup"] as? [String: Any])?["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["languageCodes"] as? [String], [])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
    }

    func testActivityMessagesAreEmptyObjects() throws {
        let start = try XCTUnwrap(try json(GeminiLiveProtocol.activityStartMessage())["realtimeInput"] as? [String: Any])
        XCTAssertEqual(start.count, 1)
        XCTAssertNotNil(start["activityStart"] as? [String: Any])
        let end = try XCTUnwrap(try json(GeminiLiveProtocol.activityEndMessage())["realtimeInput"] as? [String: Any])
        XCTAssertEqual(end.count, 1)
        XCTAssertNotNil(end["activityEnd"] as? [String: Any])
    }

    func testAudioMessageCarriesBase64PcmAndMimeType() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let input = try XCTUnwrap(try json(GeminiLiveProtocol.audioMessage(pcm: pcm))["realtimeInput"] as? [String: Any])
        XCTAssertEqual(input.count, 1)
        let audio = try XCTUnwrap(input["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(audio["data"] as? String)), pcm)
    }

    // MARK: - Server messages

    func testDecodesSetupComplete() {
        XCTAssertEqual(GeminiLiveProtocol.events(from: Data(#"{"setupComplete":{}}"#.utf8)), [.setupComplete])
    }

    func testDecodesInterim() {
        let data = Data(#"{"serverContent":{"interimInputTranscription":{"text":"the quick"}}}"#.utf8)
        XCTAssertEqual(GeminiLiveProtocol.events(from: data), [.interim("the quick")])
    }

    func testDecodesFinalAndGenerationCompleteInOrder() {
        let data = Data(#"{"serverContent":{"generationComplete":true,"inputTranscription":{"text":"The quick brown fox."}}}"#.utf8)
        XCTAssertEqual(GeminiLiveProtocol.events(from: data), [.final("The quick brown fox."), .generationComplete])
    }

    func testDecodesTurnCompleteGoAwayAndError() {
        XCTAssertEqual(GeminiLiveProtocol.events(from: Data(#"{"serverContent":{"turnComplete":true}}"#.utf8)), [.turnComplete])
        XCTAssertEqual(GeminiLiveProtocol.events(from: Data(#"{"goAway":{"timeLeft":"10s"}}"#.utf8)), [.goAway])
        XCTAssertEqual(
            GeminiLiveProtocol.events(from: Data(#"{"error":{"message":"quota"}}"#.utf8)),
            [.error("quota")]
        )
    }

    func testUnknownOrInvalidMessagesDecodeToNoEvents() {
        XCTAssertEqual(GeminiLiveProtocol.events(from: Data(#"{"sessionResumptionUpdate":{}}"#.utf8)), [])
        XCTAssertEqual(GeminiLiveProtocol.events(from: Data("not json".utf8)), [])
    }

    func testDecodesUsageMetadataWithMissingCountsAsZero() {
        let data = Data(#"{"usageMetadata":{"promptTokenCount":250,"responseTokenCount":30,"totalTokenCount":280}}"#.utf8)
        XCTAssertEqual(
            GeminiLiveProtocol.events(from: data),
            [.usage(GeminiLiveUsage(promptTokens: 250, responseTokens: 30, thoughtsTokens: 0, totalTokens: 280))]
        )
    }

    func testUsageCostBillsThoughtsAtOutputPrice() {
        let usage = GeminiLiveUsage(promptTokens: 1_000_000, responseTokens: 500_000, thoughtsTokens: 500_000, totalTokens: 2_000_000)
        XCTAssertEqual(usage.estimatedDollars, 3.50 + 21.00, accuracy: 0.0001)
    }

    func testUnknownMessageKeysSkipsHandledOnes() {
        let data = Data(#"{"serverContent":{},"usageMetadata":{},"sessionResumptionUpdate":{}}"#.utf8)
        XCTAssertEqual(GeminiLiveProtocol.unknownMessageKeys(in: data), ["sessionResumptionUpdate"])
    }

    func testJoinSegmentsAddsSpaceOnlyAtBareSeams() {
        XCTAssertEqual(GeminiLiveProtocol.joinSegments(["Hello.", "World."]), "Hello. World.")
        XCTAssertEqual(GeminiLiveProtocol.joinSegments(["Hello. ", "World."]), "Hello. World.")
        XCTAssertEqual(GeminiLiveProtocol.joinSegments(["Hello.", "", " World. "]), "Hello. World.")
        XCTAssertEqual(GeminiLiveProtocol.joinSegments([]), "")
    }

    // MARK: - Language mapping

    private func code(_ whisperCode: String, region: String?) -> [String] {
        GeminiLiveProtocol.languageCodes(for: Language(rawValue: whisperCode)!, regionCode: region)
    }

    func testAutoSendsNoLanguageCodes() {
        XCTAssertEqual(GeminiLiveProtocol.languageCodes(for: .auto, regionCode: "BR"), [])
    }

    func testRegionPicksRegionalVariant() {
        XCTAssertEqual(code("pt", region: "BR"), ["pt-BR"])
        XCTAssertEqual(code("pt", region: "PT"), ["pt-PT"])
        XCTAssertEqual(code("en", region: "GB"), ["en-GB"])
        XCTAssertEqual(code("en", region: "IN"), ["en-IN"])
        XCTAssertEqual(code("es", region: "US"), ["es-US"])
    }

    func testOtherRegionsGetTheDefaultVariant() {
        XCTAssertEqual(code("pt", region: "US"), ["pt-BR"])
        XCTAssertEqual(code("pt", region: nil), ["pt-BR"])
        XCTAssertEqual(code("en", region: "BR"), ["en-US"])
        XCTAssertEqual(code("es", region: "ES"), ["es-419"])
        XCTAssertEqual(code("de", region: "AT"), ["de-DE"])
    }

    func testWhisperSpecificCodesMapToGeminiCodes() {
        XCTAssertEqual(code("zh", region: nil), ["cmn-Hans-CN"])
        XCTAssertEqual(code("yue", region: nil), ["yue-Hant-HK"])
        XCTAssertEqual(code("no", region: nil), ["nb-NO"])
        XCTAssertEqual(code("jw", region: nil), ["jv-ID"])
        XCTAssertEqual(code("tl", region: nil), ["fil-PH"])
    }

    func testLanguagesGeminiLacksFallBackToAutoDetect() {
        XCTAssertEqual(code("la", region: nil), [])
        XCTAssertEqual(code("ta", region: "IN"), [])
    }

    func testEveryMappedKeyIsAWhisperLanguage() {
        for key in GeminiLiveProtocol.supportedLanguageCodes.keys {
            XCTAssertNotNil(Language(rawValue: key), "\(key) is not a whisper code")
        }
    }

    // MARK: - Chunking

    func testChunkerEmitsFixedChunksAndFlushesRemainder() {
        var chunker = PCMChunker(chunkBytes: 4)
        chunker.append(Data([1, 2, 3]))
        XCTAssertNil(chunker.nextFullChunk())
        chunker.append(Data([4, 5, 6, 7, 8, 9]))
        XCTAssertEqual(chunker.nextFullChunk(), Data([1, 2, 3, 4]))
        XCTAssertEqual(chunker.nextFullChunk(), Data([5, 6, 7, 8]))
        XCTAssertNil(chunker.nextFullChunk())
        XCTAssertEqual(chunker.flush(), Data([9]))
        XCTAssertNil(chunker.flush())
    }

    // MARK: - Config

    func testConfigDefaultsToSmartAndRoundTripsMode() throws {
        XCTAssertEqual(Config().geminiLiveMode, .smart)
        var config = Config()
        config.transcriptionEngine = .geminiLive
        config.geminiLiveMode = .verbatim
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.transcriptionEngine, .geminiLive)
        XCTAssertEqual(decoded.geminiLiveMode, .verbatim)
        XCTAssertEqual(decoded.selectedModelName, "gemini-3.5-transcribe-live")
    }

    // MARK: - Fallback

    func testMissingSessionFallsBackOnce() async throws {
        let calls = CallCounter()
        let result = try await GeminiLiveBackend.transcribe(
            session: nil,
            audioFile: URL(fileURLWithPath: "/nonexistent.wav"),
            config: Config()
        ) { audioFile, config in
            await calls.increment()
            return TranscriptionResult(text: "batch", language: config.selectedLanguage, durationSeconds: 0, audioFilePath: audioFile)
        }
        XCTAssertEqual(result.text, "batch")
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testCancelledSessionThrowsWithoutFallback() async throws {
        // Never started, so cancel() touches no network.
        let session = GeminiLiveSession(apiKey: "unused", languageCodes: [], mode: .verbatim)
        session.cancel()
        let calls = CallCounter()
        do {
            _ = try await GeminiLiveBackend.transcribe(
                session: session,
                audioFile: URL(fileURLWithPath: "/nonexistent.wav"),
                config: Config()
            ) { _, _ in
                await calls.increment()
                throw AppError.transcriptionEmpty
            }
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

// MARK: - Live API

final class GeminiLiveSessionLiveTests: XCTestCase {
    private var scratchDirectory: URL?

    override func tearDownWithError() throws {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    /// Real streaming round trip: a `say` clip streamed in real time as 100 ms
    /// chunks, then activityEnd and the final transcript. Billed: runs only
    /// with `BilledGeminiTests.apiKey()` opted in, and only when the streaming
    /// path changes. The fallback must not fire.
    func testLiveStreamingTranscriptionOfSpokenWav() async throws {
        let apiKey = try BilledGeminiTests.apiKey()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiLiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectory = directory
        let aiffURL = directory.appendingPathComponent("speech.aiff")
        let wavURL = directory.appendingPathComponent("speech.wav")
        try runTool("/usr/bin/say", ["-o", aiffURL.path, "The quick brown fox jumps over the lazy dog."])
        try runTool("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiffURL.path, wavURL.path])
        let pcm = try pcmData(fromWav: wavURL)

        var config = Config()
        config.selectedLanguage = .english
        config.sentencePerLine = false
        config.lineWrapEnabled = false

        let previews = PreviewLog()
        let session = GeminiLiveSession(
            apiKey: apiKey,
            languageCodes: GeminiLiveProtocol.languageCodes(for: .english, regionCode: "US"),
            mode: .verbatim,
            onPreview: { text in previews.append(text) }
        )
        session.start()
        // Recorder-sized buffers (~20 ms) in real time, like the mic tap.
        let bufferBytes = 640
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + bufferBytes, pcm.count)
            session.appendPCM(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(for: .milliseconds(20))
        }

        let result = try await GeminiLiveBackend.transcribe(session: session, audioFile: wavURL, config: config) { _, _ in
            XCTFail("Live session fell back to the batch call")
            throw AppError.transcriptionEmpty
        }
        let metrics = session.metrics
        print(
            "Gemini Live transcript: \"\(result.text)\" openMs=\(metrics.openMilliseconds ?? -1) "
                + "setupMs=\(metrics.setupMilliseconds ?? -1) stopToFinalMs=\(metrics.stopToFinalMilliseconds ?? -1) "
                + "audioSeconds=\(String(format: "%.2f", metrics.audioSeconds)) interims=\(metrics.interimCount) "
                + "finals=\(metrics.finalSegmentCount) lastPreviews=\(previews.last(3))"
        )
        XCTAssertTrue(result.text.lowercased().contains("quick brown fox"), "Unexpected transcript: \(result.text)")
        XCTAssertNotNil(metrics.setupMilliseconds)
        XCTAssertNotNil(metrics.stopToFinalMilliseconds)
    }

    private func pcmData(fromWav url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = bytes[offset + 4..<offset + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if id == "data" { return bytes.subdata(in: offset + 8..<min(bytes.count, offset + 8 + size)) }
            offset += 8 + size + (size % 2)
        }
        throw AppError.transcriptionFailed("no data chunk in \(url.lastPathComponent)")
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

private final class PreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ text: String) {
        lock.lock()
        entries.append(text)
        lock.unlock()
    }

    func last(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(count))
    }
}
