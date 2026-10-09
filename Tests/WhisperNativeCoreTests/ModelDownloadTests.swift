import CryptoKit
import XCTest
@testable import WhisperNativeCore

final class ModelDownloadTests: XCTestCase {

    private var tempDir: URL!
    private let payload = Data("model bytes".utf8)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func source(sizeBytes: Int64? = nil, sha256: String? = nil) throws -> ModelDownload {
        let url = tempDir.appendingPathComponent("source.bin")
        try payload.write(to: url)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return ModelDownload(url: url, sizeBytes: sizeBytes ?? Int64(payload.count), sha256: sha256 ?? digest)
    }

    private var destination: URL { tempDir.appendingPathComponent("models/ggml-test.bin") }
    private var partial: URL { destination.appendingPathExtension("partial") }

    func testVerifiedDownloadMovesIntoPlace() async throws {
        try await ModelManager.download(try source(), to: destination) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testChecksumMismatchKeepsTheExistingFileAndDropsThePartial() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        do {
            try await ModelManager.download(try source(sha256: String(repeating: "0", count: 64)), to: destination) { _ in }
            XCTFail("expected a checksum error")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testTruncatedDownloadIsRejected() async throws {
        do {
            try await ModelManager.download(try source(sizeBytes: Int64(payload.count) + 1), to: destination) { _ in }
            XCTFail("expected a size error")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testCatalogPinsACommitAndHasChecksums() {
        for download in ModelManager.catalog.map(\.download) + [Constants.vadModelDownload] {
            XCTAssertFalse(download.url.path.contains("/resolve/main/"), download.url.absoluteString)
            XCTAssertEqual(download.sha256.count, 64, download.url.absoluteString)
        }
    }
}
