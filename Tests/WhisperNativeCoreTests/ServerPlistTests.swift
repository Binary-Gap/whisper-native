import XCTest
@testable import WhisperNativeCore

final class ServerPlistTests: XCTestCase {

    private func makeArguments() -> [String] {
        ServerPlist.arguments(
            binaryPath: "/bin/whisper-server",
            modelPath: URL(fileURLWithPath: "/models/ggml-base.bin"),
            vadModelPath: nil,
            tmpDir: URL(fileURLWithPath: "/tmp-dir")
        )
    }

    // --convert makes whisper-server exit at start when ffmpeg isn't installed.
    func testArgumentsNeverAskForFfmpegConversion() {
        XCTAssertFalse(makeArguments().contains("--convert"))
    }

    func testArgumentsUseThreadCount() throws {
        let args = makeArguments()
        let threadsIndex = try XCTUnwrap(args.firstIndex(of: "-t"))
        XCTAssertEqual(args[threadsIndex + 1], String(ServerPlist.threadCount()))
    }

    func testThreadCountFollowsCoresWithinBounds() {
        XCTAssertEqual(ServerPlist.threadCount(activeProcessorCount: 0), 1)
        XCTAssertEqual(ServerPlist.threadCount(activeProcessorCount: 4), 4)
        XCTAssertEqual(ServerPlist.threadCount(activeProcessorCount: 12), 12)
        XCTAssertEqual(ServerPlist.threadCount(activeProcessorCount: 24), 12)
    }
}
