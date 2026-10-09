import FluidAudio
import Foundation

/// What a model row shows: not on disk, downloading (fraction 0...1, nil when
/// the downloader reports no byte progress), on disk, or on disk and in use.
public enum ModelAvailability: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double?)
    case downloaded
    case inUse

    /// A running download wins over the on-disk state; an on-disk model is in
    /// use when something blocks deleting it.
    public static func resolve(
        isDownloaded: Bool,
        isDownloading: Bool,
        downloadFraction: Double? = nil,
        isInUse: Bool
    ) -> ModelAvailability {
        if isDownloading { return .downloading(fraction: downloadFraction) }
        guard isDownloaded else { return .notDownloaded }
        return isInUse ? .inUse : .downloaded
    }

    public var isOnDisk: Bool {
        switch self {
        case .downloaded, .inUse: true
        case .notDownloaded, .downloading: false
        }
    }
}

/// The two FluidAudio models Parakeet runs: the TDT v3 speech model and the
/// Silero VAD that trims silence (also used by Start on voice).
public enum ParakeetModelKind: String, CaseIterable, Identifiable, Sendable {
    case speech
    case vad

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .speech: "Parakeet TDT v3"
        case .vad: "Voice detection (Parakeet)"
        }
    }

    /// Download size shown before the model is on disk.
    public var approxSizeLabel: String {
        switch self {
        case .speech: "~460 MB"
        case .vad: "~1 MB"
        }
    }

    /// The model's folder under FluidAudio's models root, named by FluidAudio's
    /// own repo table (`parakeet-tdt-0.6b-v3`, `silero-vad`).
    public func directory(in modelsRoot: URL = ParakeetModelKind.defaultModelsRoot) -> URL {
        switch self {
        case .speech: modelsRoot.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
        case .vad: modelsRoot.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        }
    }

    /// `~/Library/Application Support/FluidAudio/Models`.
    public static var defaultModelsRoot: URL {
        MLModelConfigurationUtils.defaultModelsDirectory()
    }

    /// True when every compiled model FluidAudio loads for this kind is in its
    /// folder (FluidAudio's own check for the speech model).
    public func isDownloaded(in modelsRoot: URL = ParakeetModelKind.defaultModelsRoot) -> Bool {
        let folder = directory(in: modelsRoot)
        switch self {
        case .speech:
            return AsrModels.modelsExist(at: folder, version: ParakeetBackend.modelVersion)
        case .vad:
            return ModelNames.VAD.requiredModels.allSatisfy {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        }
    }
}

public enum ModelStorageError: LocalizedError, Equatable {
    case inUse(String)

    public var errorDescription: String? {
        switch self {
        case .inUse(let reason): reason
        }
    }
}

/// File-level model bookkeeping shared by the Whisper and Parakeet pages:
/// what counts as downloaded, why a model can't be deleted, its size, and the
/// delete itself.
public enum ModelStorage {

    // MARK: Downloaded

    /// A single-file model (whisper `.bin`, whisper VAD) counts as downloaded
    /// when a non-empty regular file sits at `url`. An in-flight download
    /// writes to `<name>.partial`, so it never counts.
    public static func isFileDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    // MARK: In use

    /// Why the whisper model at `url` can't be deleted: it's the selected one.
    public static func whisperModelInUseReason(_ url: URL, config: Config) -> String? {
        guard sameFile(url, config.modelPath) else { return nil }
        return "In use: this is the selected Whisper model. Select another model to delete it."
    }

    /// Why the whisper VAD model at `url` can't be deleted: it's the selected
    /// VAD model the whisper server trims silence with.
    public static func whisperVadInUseReason(_ url: URL, config: Config) -> String? {
        guard let vadModelPath = config.vadModelPath, sameFile(url, vadModelPath) else { return nil }
        return "In use: Whisper trims silence with this model."
    }

    /// Why a Parakeet model can't be deleted: Parakeet is the active engine or
    /// is loaded (`parakeetLoaded`, loading counts), and the VAD also while
    /// Start on voice listens with it.
    public static func parakeetInUseReason(
        _ kind: ParakeetModelKind,
        config: Config,
        parakeetLoaded: Bool
    ) -> String? {
        if config.transcriptionEngine == .parakeet { return "In use: Parakeet is the active engine." }
        if parakeetLoaded { return "In use: Parakeet is loaded. Switch engines or quit the app to delete it." }
        if kind == .vad, config.startOnVoice { return "In use: auto-start when you speak listens with this model." }
        return nil
    }

    // MARK: Size

    /// Bytes on disk: the file's size, or the sum of every file under a folder.
    /// Zero when nothing is there.
    public static func sizeOnDisk(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Size label for a model row: the real size once on disk, else the
    /// approximate download size.
    public static func sizeLabel(onDisk url: URL?, approx: String) -> String {
        guard let url else { return approx }
        let bytes = sizeOnDisk(url)
        guard bytes > 0 else { return approx }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Delete

    /// Deletes a model file or folder, plus a leftover `<name>.partial`
    /// download next to it. Refuses with `ModelStorageError.inUse` when
    /// `inUseReason` is set; a model already gone counts as deleted.
    public static func delete(_ url: URL, inUseReason: String?) throws {
        if let inUseReason { throw ModelStorageError.inUse(inUseReason) }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: url.appendingPathExtension("partial"))
        AppLogger.shared.log(.info, "Deleted model \(url.lastPathComponent)")
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
