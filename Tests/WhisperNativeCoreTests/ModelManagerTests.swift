import XCTest
@testable import WhisperNativeCore

final class ModelManagerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ name: String, bytes: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    // MARK: Catalog

    func testRecommendedModelIsTheDefaultModel() {
        XCTAssertEqual(ModelManager.recommendedModel.fileName, Constants.defaultModelFileName)
        XCTAssertEqual(ModelManager.catalog.filter(\.isRecommended).count, 1)
    }

    func testEveryCatalogModelHasAHint() {
        for model in ModelManager.catalog {
            XCTAssertFalse(model.hint.isEmpty, model.fileName)
            XCTAssertGreaterThan(model.approxSizeBytes, 0, model.fileName)
        }
    }

    // MARK: List order

    func testListSortsBySizeSmallestFirstWhateverIsDownloaded() throws {
        // A downloaded large model doesn't jump ahead of smaller ones.
        try makeFile("ggml-large-v3.bin", bytes: 10)
        let names = ModelManager.listItems(in: tempDir).map(\.displayName)
        XCTAssertEqual(names, ["tiny", "base", "small", "medium", "large-v3-turbo", "large-v3"])
    }

    func testListPlacesExtraModelsByFileSize() throws {
        try makeFile("ggml-custom.bin", bytes: 4096)
        let items = ModelManager.listItems(in: tempDir)
        // 4 KB is smaller than every catalog model.
        XCTAssertEqual(items.first?.displayName, "custom")
        XCTAssertNil(items.first?.hint)
        XCTAssertEqual(items.first?.isRecommended, false)
        XCTAssertTrue(items.first?.isDownloaded == true)
    }

    func testListMarksOnlyTheRecommendedModel() {
        let items = ModelManager.listItems(in: tempDir)
        XCTAssertEqual(items.filter(\.isRecommended).map(\.fileName), [Constants.defaultModelFileName])
        XCTAssertEqual(items.first { $0.isRecommended }?.hint, "Fast, very accurate")
    }

    func testListSkipsVadModels() throws {
        try makeFile("ggml-silero-v6.2.0.bin", bytes: 10)
        XCTAssertFalse(ModelManager.listItems(in: tempDir).contains { $0.fileName.contains("silero") })
    }

    // MARK: Fallback

    func testFallbackIsNilWithNothingDownloaded() {
        XCTAssertNil(ModelManager.fallbackModel(in: ModelManager.listItems(in: tempDir)))
    }

    func testFallbackPrefersTheRecommendedModel() throws {
        try makeFile("ggml-tiny.bin", bytes: 10)
        let turbo = try makeFile(Constants.defaultModelFileName, bytes: 10)
        XCTAssertEqual(ModelManager.fallbackModel(in: ModelManager.listItems(in: tempDir))?.lastPathComponent, turbo.lastPathComponent)
    }

    func testFallbackOtherwiseTakesTheSmallestDownloadedModel() throws {
        try makeFile("ggml-large-v3.bin", bytes: 10)
        let small = try makeFile("ggml-small.bin", bytes: 10)
        XCTAssertEqual(ModelManager.fallbackModel(in: ModelManager.listItems(in: tempDir))?.lastPathComponent, small.lastPathComponent)
    }
}
