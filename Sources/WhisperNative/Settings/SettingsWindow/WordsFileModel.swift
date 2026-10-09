import AppKit
import SwiftUI
import WhisperNativeCore

/// The words file (`words.yml`) as Settings shows it, shared by the Gemini
/// vocabulary section and the stop words row. The file is the source of truth,
/// so any tool can edit it: `watch()` re-stats it every second while its view
/// is visible and reparses when it changed (editors often save by replacing
/// the file, so the path is checked, not an open handle).
@MainActor
final class WordsFileModel: ObservableObject {
    private static let pollInterval: Duration = .seconds(1)

    let location: WordsFile.Location
    @Published private(set) var fileState: WordsFile.FileState = .missing
    /// Why the last Edit… failed, nil once it worked.
    @Published private(set) var errorMessage: String?

    private var fileStamp: FileStamp?
    private var hasLoaded = false

    init(location: WordsFile.Location = .standard) {
        self.location = location
    }

    /// The file's path with `~` for the home folder.
    var displayPath: String {
        (location.url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    var fileName: String { location.url.lastPathComponent }

    /// Reloads the file whenever it changes until the calling task is cancelled
    /// (run it from the view's `.task`).
    func watch() async {
        while !Task.isCancelled {
            reloadIfChanged()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Creates or completes the file for `languages` and opens it in the
    /// default editor (TextEdit when .yml has no default app).
    func openInEditor(languages: [Language]) {
        let url = location.url
        do {
            try WordsFile.prepareForEditing(at: location, languages: languages)
            errorMessage = nil
        } catch {
            AppLogger.shared.log(.error, "Words file: failed to prepare \(url.lastPathComponent): \(error.localizedDescription)")
            errorMessage = "Couldn't prepare \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        if !NSWorkspace.shared.open(url) {
            guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
                AppLogger.shared.log(.error, "Words file: no app opened \(url.lastPathComponent)")
                errorMessage = "No app could open \(url.lastPathComponent)."
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
        reloadIfChanged()
    }

    /// Modification date + size of the file at the path, nil when it is missing.
    private struct FileStamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private func currentStamp() -> FileStamp? {
        guard let values = try? location.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return FileStamp(modified: values.contentModificationDate, size: values.fileSize)
    }

    private func reloadIfChanged() {
        let stamp = currentStamp()
        guard !hasLoaded || stamp != fileStamp else { return }
        hasLoaded = true
        fileStamp = stamp
        // Reading also migrates an older vocabulary file; the next poll sees
        // the new file's stamp and rereads it.
        let state = WordsFile.read(at: location)
        if state != fileState { fileState = state }
    }
}
