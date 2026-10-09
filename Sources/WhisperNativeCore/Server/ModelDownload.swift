import CryptoKit
import Foundation

/// A model file pinned to one Hugging Face commit, with the exact size and
/// SHA-256 the download must have before it replaces anything on disk.
public struct ModelDownload: Hashable, Sendable {
    public let url: URL
    public let sizeBytes: Int64
    public let sha256: String

    public init(url: URL, sizeBytes: Int64, sha256: String) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    /// `ggerganov/whisper.cpp` at the commit the whisper catalog was checked against.
    static func whisperModel(_ fileName: String, sizeBytes: Int64, sha256: String) -> ModelDownload {
        huggingFace(repo: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
                    fileName: fileName, sizeBytes: sizeBytes, sha256: sha256)
    }

    /// `ggml-org/whisper-vad` at the commit the VAD model was checked against.
    static func vadModel(_ fileName: String, sizeBytes: Int64, sha256: String) -> ModelDownload {
        huggingFace(repo: "ggml-org/whisper-vad", revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
                    fileName: fileName, sizeBytes: sizeBytes, sha256: sha256)
    }

    private static func huggingFace(repo: String, revision: String, fileName: String, sizeBytes: Int64, sha256: String) -> ModelDownload {
        ModelDownload(
            url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)?download=true")!,
            sizeBytes: sizeBytes,
            sha256: sha256
        )
    }
}

/// Downloads a `ModelDownload` to a `.partial` file next to the destination,
/// checks its size and SHA-256, then moves it into place. Any failure or
/// cancellation deletes the `.partial` file and leaves the destination untouched.
enum ModelDownloader {

    static func download(
        _ source: ModelDownload,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await fetch(source, to: partial, progress: progress)
            try verify(partial, against: source)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
        progress(1.0)
    }

    private static func fetch(_ source: ModelDownload, to partial: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(partial: partial, expectedBytes: source.sizeBytes, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source.url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Hashes in 4 MB chunks so a 3 GB model never sits in memory.
    private static func verify(_ file: URL, against source: ModelDownload) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == source.sizeBytes else {
            throw AppError.downloadFailed("\(file.deletingPathExtension().lastPathComponent) is \(size) bytes, expected \(source.sizeBytes)")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == source.sha256 else {
            throw AppError.downloadFailed("\(file.deletingPathExtension().lastPathComponent) failed its checksum")
        }
    }
}

/// Session delegate for one download. URLSession calls it on its own serial
/// queue; `continuation` is set before the task starts.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?
    private let partial: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private var lastReported = 0.0
    private var moveError: Error?

    init(partial: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.partial = partial
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = Double(totalBytesWritten) / Double(expectedBytes)
        if fraction - lastReported >= 0.01 {
            lastReported = fraction
            progress(min(fraction, 1))
        }
    }

    // The temporary file is deleted when this returns, so it moves now; the
    // HTTP status is checked once the task completes.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Void, Error>
        if let error {
            result = .failure(error)
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(AppError.downloadFailed("HTTP \(http.statusCode) for \(partial.deletingPathExtension().lastPathComponent)"))
        } else if let moveError {
            result = .failure(moveError)
        } else {
            result = .success(())
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
