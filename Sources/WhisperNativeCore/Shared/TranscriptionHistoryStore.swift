import Combine
import Foundation

/// JSON-backed store of transcription history entries. Loads once into memory,
/// atomically re-writes on every mutation, and publishes `entries` (newest first)
/// so SwiftUI views re-render on add/update/delete.
///
/// Keeps the newest `maxItems` entries as a usage log (text and metadata are
/// small); only the newest `maxAudioFiles` of them keep their WAV, so the
/// history dir stays bounded.
/// File deletions are best-effort (a locked/missing file never aborts a mutation).
@MainActor
public final class TranscriptionHistoryStore: ObservableObject {
    public static let shared = TranscriptionHistoryStore()

    @Published public private(set) var entries: [HistoryEntry] = []

    private let metadataURL: URL
    private let maxItems: Int
    private let maxAudioFiles: Int
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(
        metadataURL: URL = Constants.historyMetadataURL,
        maxItems: Int = Constants.maxHistoryItems,
        maxAudioFiles: Int = Constants.maxHistoryAudioFiles
    ) {
        self.metadataURL = metadataURL
        self.maxItems = maxItems
        self.maxAudioFiles = maxAudioFiles
        reload()
    }

    // MARK: - Mutations

    public func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        trimToCap()
        deleteAgedOutAudioFiles()
        save()
    }

    /// Replaces the stored entry with the same `id`; no-op if absent.
    public func update(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    /// Removes the entry and best-effort deletes its backing WAV.
    public func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        deleteAudioFile(removed)
        save()
    }

    public func reload() {
        guard let data = try? Data(contentsOf: metadataURL) else {
            entries = []
            return
        }
        do {
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            AppLogger.shared.log(.warning, "History metadata decode failed: \(error)")
            entries = []
        }
    }

    // MARK: - Private

    private func trimToCap() {
        guard entries.count > maxItems else { return }
        for entry in entries[maxItems...] {
            deleteAudioFile(entry)
        }
        entries = Array(entries.prefix(maxItems))
    }

    private func deleteAgedOutAudioFiles() {
        guard entries.count > maxAudioFiles else { return }
        for entry in entries[maxAudioFiles...]
        where FileManager.default.fileExists(atPath: entry.audioFilePath.path) {
            deleteAudioFile(entry)
        }
    }

    private func deleteAudioFile(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: entry.audioFilePath)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: metadataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(entries)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            AppLogger.shared.log(.error, "History metadata save failed: \(error)")
        }
    }
}
