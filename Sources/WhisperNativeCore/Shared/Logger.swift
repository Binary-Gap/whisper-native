import Foundation

public enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

public final class AppLogger: Sendable {
    public static let shared = AppLogger()

    private let logFileURL: URL
    private let fileHandle: FileHandleWrapper
    // ISO8601DateFormatter's formatting is thread-safe; safe to share across the
    // serialized log calls without per-call allocation.
    private nonisolated(unsafe) let timestampFormatter = ISO8601DateFormatter()

    private init() {
        let logDir = Constants.logDirectory
        let logFile = logDir.appendingPathComponent("whisper-native.log")
        logFileURL = logFile

        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
        } catch {
            // Can't log the log failure — stderr is the only fallback
            fputs("AppLogger init failed to create log directory: \(error)\n", stderr)
        }

        fileHandle = FileHandleWrapper(url: logFile)
    }

    public func log(
        _ level: LogLevel,
        _ message: String,
        file: String = #file,
        function: String = #function
    ) {
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] [\(filename):\(function)] \(message)\n"

        fileHandle.write(line)

        #if DEBUG
        fputs(line, stderr)
        #endif
    }
}

// Thread-safe wrapper around FileHandle using a lock.
// Marked Sendable because access is serialized through NSLock.
private final class FileHandleWrapper: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(url: URL) {
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    deinit {
        try? handle?.close()
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8), let handle else { return }
        lock.withLock {
            handle.write(data)
        }
    }
}
