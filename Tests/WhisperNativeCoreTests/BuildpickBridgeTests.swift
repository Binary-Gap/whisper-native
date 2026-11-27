import XCTest
@testable import WhisperNativeCore

/// Runs the bridge against a stub `cc-remote` script that records its arguments
/// and the text file's content, then exits with a chosen code.
final class BuildpickBridgeTests: XCTestCase {
    private var stubDirectory: URL!

    override func setUpWithError() throws {
        stubDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BuildpickBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stubDirectory)
    }

    private var argumentsLog: URL { stubDirectory.appendingPathComponent("arguments.txt") }
    private var textLog: URL { stubDirectory.appendingPathComponent("text.txt") }

    /// A stub command whose body runs after it logs its arguments and copies
    /// the `--text-file` it was given.
    private func stubBridge(body: String, timeout: TimeInterval = 5) throws -> BuildpickBridge {
        let script = stubDirectory.appendingPathComponent("cc-remote")
        let source = """
        #!/bin/sh
        echo "$@" > '\(argumentsLog.path)'
        if [ "$3" = "--text-file" ]; then cat "$4" > '\(textLog.path)'; fi
        \(body)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return BuildpickBridge(commandPath: script.path, focusedTimeout: timeout, sendTimeout: timeout)
    }

    private func loggedArguments() throws -> String {
        try String(contentsOf: argumentsLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testFocusedReturnsTheSessionID() throws {
        let bridge = try stubBridge(body: "echo abc-123")
        XCTAssertEqual(bridge.focusedSessionID(), "abc-123")
        XCTAssertEqual(try loggedArguments(), "focused")
    }

    func testFocusedWithEmptyOutputIsNil() throws {
        let bridge = try stubBridge(body: "exit 0")
        XCTAssertNil(bridge.focusedSessionID())
    }

    func testFocusedFailureIsNil() throws {
        let bridge = try stubBridge(body: "echo 'no server answered' >&2; exit 1")
        XCTAssertNil(bridge.focusedSessionID())
    }

    func testSendPassesSessionAndText() async throws {
        let bridge = try stubBridge(body: "exit 0")
        let sent = await bridge.send("hello there", toSession: "s1")
        XCTAssertTrue(sent)
        XCTAssertTrue(try loggedArguments().hasPrefix("send s1 --text-file "))
        XCTAssertEqual(try String(contentsOf: textLog, encoding: .utf8), "hello there")
    }

    func testDraftPassesSessionAndText() async throws {
        let bridge = try stubBridge(body: "exit 0")
        let drafted = await bridge.draft("keep me", toSession: "s2")
        XCTAssertTrue(drafted)
        XCTAssertTrue(try loggedArguments().hasPrefix("draft s2 --text-file "))
        XCTAssertEqual(try String(contentsOf: textLog, encoding: .utf8), "keep me")
    }

    func testSendFailureReturnsFalse() async throws {
        let bridge = try stubBridge(body: "echo 'no Buildpick server has session s1' >&2; exit 1")
        let sent = await bridge.send("hello", toSession: "s1")
        XCTAssertFalse(sent)
    }

    func testSendTimeoutReturnsFalse() async throws {
        let bridge = try stubBridge(body: "sleep 30", timeout: 0.5)
        let start = Date()
        let sent = await bridge.send("hello", toSession: "s1")
        XCTAssertFalse(sent)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMissingCommandFailsWithoutRunning() async {
        let bridge = BuildpickBridge(commandPath: nil)
        XCTAssertNil(bridge.focusedSessionID())
        let sent = await bridge.send("hello", toSession: "s1")
        XCTAssertFalse(sent)
    }
}
