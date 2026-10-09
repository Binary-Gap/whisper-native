import XCTest
@testable import WhisperNativeCore

final class ProcessRunnerTests: XCTestCase {

    func testReturnsExitCodeAndOutput() async throws {
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertFalse(result.timedOut)
    }

    func testOutputLargerThanThePipeBufferDoesNotBlock() async throws {
        // 1 MB of output, far past the 64 KB pipe buffer.
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "head -c 1048576 /dev/zero | tr '\\0' a"], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 1_048_576)
    }

    func testKillsAProcessPastItsTimeout() async throws {
        let start = Date()
        let result = try await ProcessRunner.run("/bin/sleep", arguments: ["30"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testKillsAProcessThatIgnoresSIGTERM() throws {
        let start = Date()
        let result = try ProcessRunner.runSync("/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMissingExecutableThrows() async {
        do {
            _ = try await ProcessRunner.run("/nonexistent/tool", arguments: [], timeout: 1)
            XCTFail("expected an error")
        } catch {}
    }
}
