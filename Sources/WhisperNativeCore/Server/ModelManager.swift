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
/// filename plus where to fetch it, an approximate on-disk size for the UI
/// (label, plus bytes for sorting) and a short speed/accuracy hint.
public struct CatalogModel: Identifiable, Hashable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let downloadURL: URL
    public let approxSizeLabel: String
    public let approxSizeBytes: Int64
    public let hint: String

    public init(fileName: String, downloadURL: URL, approxSizeLabel: String, approxSizeBytes: Int64, hint: String) {
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.approxSizeLabel = approxSizeLabel
        self.approxSizeBytes = approxSizeBytes
        self.hint = hint
    }

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
    /// The catalog download URL, if this model is in the known catalog.
    public let downloadURL: URL?
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
        func hf(_ file: String) -> URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)?download=true")!
        }
        return [
            CatalogModel(fileName: "ggml-tiny.bin", downloadURL: hf("ggml-tiny.bin"), approxSizeLabel: "~75 MB", approxSizeBytes: 77_700_000, hint: "Fastest, least accurate"),
            CatalogModel(fileName: "ggml-base.bin", downloadURL: hf("ggml-base.bin"), approxSizeLabel: "~142 MB", approxSizeBytes: 148_000_000, hint: "Very fast, basic accuracy"),
            CatalogModel(fileName: "ggml-small.bin", downloadURL: hf("ggml-small.bin"), approxSizeLabel: "~466 MB", approxSizeBytes: 487_600_000, hint: "Fast, good accuracy"),
            CatalogModel(fileName: "ggml-medium.bin", downloadURL: hf("ggml-medium.bin"), approxSizeLabel: "~1.5 GB", approxSizeBytes: 1_533_800_000, hint: "Slow, accurate"),
            CatalogModel(fileName: "ggml-large-v3-turbo.bin", downloadURL: hf("ggml-large-v3-turbo.bin"), approxSizeLabel: "~1.6 GB", approxSizeBytes: 1_624_600_000, hint: "Fast, very accurate"),
            CatalogModel(fileName: "ggml-large-v3.bin", downloadURL: hf("ggml-large-v3.bin"), approxSizeLabel: "~3.1 GB", approxSizeBytes: 3_095_000_000, hint: "Slowest, most accurate"),
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
                sizeBytes: entry.approxSizeBytes,
                hint: entry.hint,
                isRecommended: entry.isRecommended,
                downloadURL: entry.downloadURL,
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
                downloadURL: nil,
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

    /// Downloads a file to `destination`, reporting fractional progress (0...1).
    /// Creates the parent directory if needed. Overwrites any existing file.
    public static func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.serverUnhealthy("model download HTTP error for \(url.lastPathComponent)")
        }
        let expected = response.expectedContentLength

        let tmp = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReported = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let frac = Double(received) / Double(expected)
                    if frac - lastReported >= 0.01 {
                        lastReported = frac
                        progress(frac)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        // Move the completed download into place atomically.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
        progress(1.0)
        AppLogger.shared.log(.info, "Downloaded model \(destination.lastPathComponent) (\(received) bytes)")
    }
}
