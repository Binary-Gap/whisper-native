import XCTest
@testable import WhisperNativeCore

@MainActor
final class TranscriptionHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEntry(_ name: String) throws -> HistoryEntry {
        let audioURL = directory.appendingPathComponent("\(name).wav")
        try Data("wav".utf8).write(to: audioURL)
        return HistoryEntry(
            audioFilePath: audioURL,
            text: name,
            language: .auto,
            modelName: "model",
            status: .success,
            durationSeconds: 0.5,
            audioDurationSeconds: 3.2
        )
    }

    func testKeepsEveryEntryButOnlyTheNewestAudioFiles() throws {
        let metadataURL = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(metadataURL: metadataURL, maxAudioFiles: 2)
        let oldest = try makeEntry("first")
        let middle = try makeEntry("second")
        let newest = try makeEntry("third")
        store.add(oldest)
        store.add(middle)
        store.add(newest)

        XCTAssertEqual(store.entries.map(\.text), ["third", "second", "first"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.audioFilePath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.audioFilePath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.audioFilePath.path))

        let reloaded = TranscriptionHistoryStore(metadataURL: metadataURL, maxAudioFiles: 2)
        XCTAssertEqual(reloaded.entries.count, 3)
        XCTAssertEqual(reloaded.entries.last?.audioDurationSeconds, 3.2)
    }

    func testDropsOldestEntriesPastTheEntryCap() throws {
        let metadataURL = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(metadataURL: metadataURL, maxItems: 2, maxAudioFiles: 5)
        let oldest = try makeEntry("first")
        store.add(oldest)
        store.add(try makeEntry("second"))
        store.add(try makeEntry("third"))

        XCTAssertEqual(store.entries.map(\.text), ["third", "second"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.audioFilePath.path))
    }

    func testDecodesEntriesWrittenWithoutAudioDuration() throws {
        let metadataURL = directory.appendingPathComponent("history.json")
        let json = #"""
        [{"audioFilePath":"file:///missing.wav","durationSeconds":1.5,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "language":"pt","modelName":"model","status":"success","text":"oi","timestamp":"2026-09-25T20:18:28Z"}]
        """#
        try Data(json.utf8).write(to: metadataURL)
        let store = TranscriptionHistoryStore(metadataURL: metadataURL)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNil(store.entries.first?.audioDurationSeconds)
        XCTAssertNil(store.entries.first?.transcriptionMode)
        XCTAssertEqual(store.entries.first?.durationSeconds, 1.5)
    }

    func testPersistsTranscriptionMode() throws {
        let metadataURL = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(metadataURL: metadataURL)
        var entry = try makeEntry("live")
        entry.transcriptionMode = GeminiLiveMode.smart.rawValue
        store.add(entry)

        let reloaded = TranscriptionHistoryStore(metadataURL: metadataURL)
        XCTAssertEqual(reloaded.entries.first?.transcriptionMode, "SMART")
        XCTAssertEqual(reloaded.entries.first?.transcriptionModeLabel, "Smart")
    }

    func testPersistsEstimatedCost() throws {
        let metadataURL = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(metadataURL: metadataURL)
        var entry = try makeEntry("gemini")
        entry.estimatedCostUSD = 0.0012
        store.add(entry)

        let reloaded = TranscriptionHistoryStore(metadataURL: metadataURL)
        XCTAssertEqual(reloaded.entries.first?.estimatedCostUSD, 0.0012)
    }
}
