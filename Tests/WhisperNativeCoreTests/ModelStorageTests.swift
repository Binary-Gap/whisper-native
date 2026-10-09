import XCTest
@testable import WhisperNativeCore

final class ModelStorageTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ name: String, bytes: Int, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    // MARK: Availability

    func testAvailabilityPrefersDownloadingOverDiskState() {
        XCTAssertEqual(
            ModelAvailability.resolve(isDownloaded: true, isDownloading: true, downloadFraction: 0.4, isInUse: true),
            .downloading(fraction: 0.4)
        )
    }

    func testAvailabilityOnDiskStates() {
        XCTAssertEqual(ModelAvailability.resolve(isDownloaded: false, isDownloading: false, isInUse: true), .notDownloaded)
        XCTAssertEqual(ModelAvailability.resolve(isDownloaded: true, isDownloading: false, isInUse: false), .downloaded)
        XCTAssertEqual(ModelAvailability.resolve(isDownloaded: true, isDownloading: false, isInUse: true), .inUse)
        XCTAssertTrue(ModelAvailability.inUse.isOnDisk)
        XCTAssertFalse(ModelAvailability.downloading(fraction: nil).isOnDisk)
    }

    // MARK: Downloaded

    func testFileDownloadedNeedsNonEmptyRegularFile() throws {
        let model = try makeFile("ggml-tiny.bin", bytes: 10)
        let empty = try makeFile("ggml-base.bin", bytes: 0)
        try makeFile("ggml-small.bin.partial", bytes: 10)

        XCTAssertTrue(ModelStorage.isFileDownloaded(model))
        XCTAssertFalse(ModelStorage.isFileDownloaded(empty))
        XCTAssertFalse(ModelStorage.isFileDownloaded(tempDir.appendingPathComponent("ggml-small.bin")))
        XCTAssertFalse(ModelStorage.isFileDownloaded(tempDir))
    }

    func testParakeetFoldersUseFluidAudioNames() {
        XCTAssertEqual(ParakeetModelKind.speech.directory(in: tempDir).lastPathComponent, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ParakeetModelKind.vad.directory(in: tempDir).lastPathComponent, "silero-vad")
    }

    func testParakeetVadDownloadedOnlyWithCompiledModel() throws {
        let folder = ParakeetModelKind.vad.directory(in: tempDir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(ParakeetModelKind.vad.isDownloaded(in: tempDir))

        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("silero-vad-unified-256ms-v6.2.1.mlmodelc"),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(ParakeetModelKind.vad.isDownloaded(in: tempDir))
    }

    func testParakeetSpeechNotDownloadedInEmptyRoot() {
        XCTAssertFalse(ParakeetModelKind.speech.isDownloaded(in: tempDir))
    }

    // MARK: In use

    func testWhisperModelInUseOnlyWhenSelected() {
        let selected = tempDir.appendingPathComponent("ggml-tiny.bin")
        let other = tempDir.appendingPathComponent("ggml-base.bin")
        let config = Config(modelsDirectory: tempDir, modelPath: selected)

        XCTAssertNotNil(ModelStorage.whisperModelInUseReason(selected, config: config))
        XCTAssertNil(ModelStorage.whisperModelInUseReason(other, config: config))
        // A differently spelled path to the same file still counts.
        let dotted = tempDir.appendingPathComponent("./ggml-tiny.bin")
        XCTAssertNotNil(ModelStorage.whisperModelInUseReason(dotted, config: config))
    }

    func testWhisperVadInUseOnlyWhenSelected() {
        let vad = tempDir.appendingPathComponent("ggml-silero-v6.2.0.bin")
        XCTAssertNotNil(ModelStorage.whisperVadInUseReason(vad, config: Config(vadModelPath: vad)))
        XCTAssertNil(ModelStorage.whisperVadInUseReason(vad, config: Config(vadModelPath: nil)))
    }

    func testParakeetInUseRules() {
        let idle = Config(transcriptionEngine: .whisper)
        XCTAssertNil(ModelStorage.parakeetInUseReason(.speech, config: idle, parakeetLoaded: false))
        XCTAssertNil(ModelStorage.parakeetInUseReason(.vad, config: idle, parakeetLoaded: false))

        let active = Config(transcriptionEngine: .parakeet)
        XCTAssertNotNil(ModelStorage.parakeetInUseReason(.speech, config: active, parakeetLoaded: false))
        XCTAssertNotNil(ModelStorage.parakeetInUseReason(.vad, config: active, parakeetLoaded: false))

        XCTAssertNotNil(ModelStorage.parakeetInUseReason(.speech, config: idle, parakeetLoaded: true))

        let voiceStart = Config(transcriptionEngine: .whisper, startOnVoice: true)
        XCTAssertNil(ModelStorage.parakeetInUseReason(.speech, config: voiceStart, parakeetLoaded: false))
        XCTAssertNotNil(ModelStorage.parakeetInUseReason(.vad, config: voiceStart, parakeetLoaded: false))
    }

    // MARK: Size

    func testSizeOnDiskForFileAndFolder() throws {
        let file = try makeFile("ggml-tiny.bin", bytes: 100)
        let folder = tempDir.appendingPathComponent("parakeet")
        try makeFile("a.bin", bytes: 30, in: folder)
        try makeFile("nested/b.bin", bytes: 70, in: folder)

        XCTAssertEqual(ModelStorage.sizeOnDisk(file), 100)
        XCTAssertEqual(ModelStorage.sizeOnDisk(folder), 100)
        XCTAssertEqual(ModelStorage.sizeOnDisk(tempDir.appendingPathComponent("missing")), 0)
    }

    func testSizeLabelFallsBackToApproxWhenMissing() {
        XCTAssertEqual(ModelStorage.sizeLabel(onDisk: nil, approx: "~1 MB"), "~1 MB")
        XCTAssertEqual(ModelStorage.sizeLabel(onDisk: tempDir.appendingPathComponent("missing"), approx: "~1 MB"), "~1 MB")
    }

    // MARK: Delete

    func testDeleteRemovesFileAndPartialLeftover() throws {
        let model = try makeFile("ggml-tiny.bin", bytes: 10)
        let partial = try makeFile("ggml-tiny.bin.partial", bytes: 5)

        try ModelStorage.delete(model, inUseReason: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testDeleteRemovesFolder() throws {
        let folder = ParakeetModelKind.vad.directory(in: tempDir)
        try makeFile("silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil", bytes: 10, in: folder)

        try ModelStorage.delete(folder, inUseReason: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(ParakeetModelKind.vad.isDownloaded(in: tempDir))
    }

    func testDeleteRefusesModelInUse() throws {
        let model = try makeFile("ggml-tiny.bin", bytes: 10)

        XCTAssertThrowsError(try ModelStorage.delete(model, inUseReason: "In use")) { error in
            XCTAssertEqual(error as? ModelStorageError, .inUse("In use"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    func testDeleteOfMissingModelSucceeds() {
        XCTAssertNoThrow(try ModelStorage.delete(tempDir.appendingPathComponent("gone.bin"), inUseReason: nil))
    }
}
