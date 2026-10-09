import Foundation

/// A whisper model file discovered in the models directory.
public struct ModelFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let sizeBytes: Int64

    public var fileName: String { url.lastPathComponent }

    /// Display name: filename minus the `ggml-`/`whisper_` prefixes and `.bin`.
    public var displayName: String {
        var name = url.deletingPathExtension().lastPathComponent
        for prefix in ["whisper_ggml-", "ggml-", "whisper_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }

    public init(url: URL, sizeBytes: Int64) {
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

/// A known whisper model in the download catalog: the canonical `ggml-*.bin`
/// filename plus where to fetch it (with its exact size and checksum), a size
/// label for the UI and a short speed/accuracy hint.
public struct CatalogModel: Identifiable, Hashable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let download: ModelDownload
    public let approxSizeLabel: String
    public let hint: String

    public init(fileName: String, download: ModelDownload, approxSizeLabel: String, hint: String) {
        self.fileName = fileName
        self.download = download
        self.approxSizeLabel = approxSizeLabel
        self.hint = hint
    }

    public var sizeBytes: Int64 { download.sizeBytes }

    /// The recommended model is the default one (`Constants.defaultModelFileName`).
    public var isRecommended: Bool { fileName == Constants.defaultModelFileName }

    /// Display name, matching `ModelFile.displayName` (strips ggml-/whisper_ + .bin).
    public var displayName: String {
        var name = (fileName as NSString).deletingPathExtension
        for prefix in ["whisper_ggml-", "ggml-", "whisper_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }
}

/// A model row in the picker: a catalog entry that may or may not be present on
/// disk. `localURL` is non-nil when the file has been downloaded.
public struct ModelListItem: Identifiable, Hashable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let displayName: String
    public let approxSizeLabel: String
    /// Sort key: the catalog's approximate size, or the file size for a model
    /// outside the catalog.
    public let sizeBytes: Int64
    /// Speed/accuracy hint from the catalog; nil for a model outside it.
    public let hint: String?
    public let isRecommended: Bool
    /// Where to fetch it, if this model is in the known catalog.
    public let download: ModelDownload?
    /// On-disk location, if the model file exists in the models directory.
    public let localURL: URL?

    public var isDownloaded: Bool { localURL != nil }
}

/// Scans a directory for whisper `.bin` models and downloads the default model +
/// VAD model from HuggingFace on first run. VAD models (silero) are excluded from
/// the selectable whisper-model listing.
public enum ModelManager {

    /// Known whisper models offered for download from HuggingFace `ggerganov/whisper.cpp`.
    /// Merged with folder-scanned files so the picker lists every model, downloaded or not.
    public static let catalog: [CatalogModel] = {
        func model(_ fileName: String, _ sizeBytes: Int64, _ sha256: String, label: String, hint: String) -> CatalogModel {
            CatalogModel(
                fileName: fileName,
                download: .whisperModel(fileName, sizeBytes: sizeBytes, sha256: sha256),
                approxSizeLabel: label,
                hint: hint
            )
        }
        return [
            model("ggml-tiny.bin", 77_691_713, "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", label: "~75 MB", hint: "Fastest, least accurate"),
            model("ggml-base.bin", 147_951_465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", label: "~142 MB", hint: "Very fast, basic accuracy"),
            model("ggml-small.bin", 487_601_967, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", label: "~466 MB", hint: "Fast, good accuracy"),
            model("ggml-medium.bin", 1_533_763_059, "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208", label: "~1.5 GB", hint: "Slow, accurate"),
            model("ggml-large-v3-turbo.bin", 1_624_555_275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", label: "~1.6 GB", hint: "Fast, very accurate"),
            model("ggml-large-v3.bin", 3_095_033_483, "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", label: "~3.1 GB", hint: "Slowest, most accurate"),
        ]
    }()

    /// The recommended (default) catalog model, offered when Whisper has none.
    public static var recommendedModel: CatalogModel {
        catalog.first(where: \.isRecommended)!
    }

    /// The downloaded model to use when the selected one isn't on disk: the
    /// recommended model when it's downloaded, else the first downloaded item
    /// (the smallest, in `listItems` order). Nil when nothing is downloaded.
    public static func fallbackModel(in items: [ModelListItem]) -> URL? {
        let downloaded = items.filter(\.isDownloaded)
        return (downloaded.first(where: \.isRecommended) ?? downloaded.first)?.localURL
    }

    /// Merges the download catalog with the on-disk scan: every catalog model
    /// plus any extra local `.bin` files, each tagged with whether it's downloaded.
    /// Sorted by size, smallest first (catalog models by their approximate
    /// size, extras by their file size), then by name.
    public static func listItems(in directory: URL) -> [ModelListItem] {
        let local = availableModels(in: directory)
        let localByName = Dictionary(uniqueKeysWithValues: local.map { ($0.fileName, $0) })

        var items: [ModelListItem] = catalog.map { entry in
            let onDisk = localByName[entry.fileName]
            return ModelListItem(
                fileName: entry.fileName,
                displayName: entry.displayName,
                approxSizeLabel: entry.approxSizeLabel,
                sizeBytes: entry.sizeBytes,
                hint: entry.hint,
                isRecommended: entry.isRecommended,
                download: entry.download,
                localURL: onDisk?.url
            )
        }

        // Local files not in the catalog (user dropped their own) show as downloaded extras.
        let catalogNames = Set(catalog.map(\.fileName))
        for model in local where !catalogNames.contains(model.fileName) {
            items.append(ModelListItem(
                fileName: model.fileName,
                displayName: model.displayName,
                approxSizeLabel: "",
                sizeBytes: model.sizeBytes,
                hint: nil,
                isRecommended: false,
                download: nil,
                localURL: model.url
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Lists `.bin` files in `directory`, excluding VAD (silero) models, sorted by
    /// name. Returns empty when the directory doesn't exist yet.
    public static func availableModels(in directory: URL) -> [ModelFile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "bin" }
            .filter { !$0.lastPathComponent.lowercased().contains("silero") }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return ModelFile(url: url, sizeBytes: Int64(size))
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// Returns the VAD (silero) model in the directory, if present.
    public static func vadModel(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        return entries.first { $0.pathExtension.lowercased() == "bin" && $0.lastPathComponent.lowercased().contains("silero") }
    }

    /// Downloads a model to `destination`, reporting fractional progress (0...1).
    /// Creates the parent directory if needed. Replaces any existing file only
    /// once the download has the expected size and checksum.
    public static func download(
        _ source: ModelDownload,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await ModelDownloader.download(source, to: destination, progress: progress)
        AppLogger.shared.log(.info, "Downloaded model \(destination.lastPathComponent) (\(source.sizeBytes) bytes)")
    }
}
