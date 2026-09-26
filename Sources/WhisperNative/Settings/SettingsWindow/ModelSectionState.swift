import Foundation
import SwiftUI
import WhisperNativeCore

/// Drives the Model section: lists all known models (catalog + folder scan),
/// downloads a chosen or default model + the VAD model, and keeps the config's
/// modelPath/vadModelPath valid.
@MainActor
public final class ModelSectionState: ObservableObject {
    @Published var items: [ModelListItem] = []
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus = ""
    @Published var errorMessage: String?
    /// Filename currently being downloaded (for the row spinner), if any.
    @Published var downloadingFileName: String?
    /// True while a model switch is being applied (server reload in flight).
    /// Selecting a model is expensive (restarts whisper-server), so rows lock
    /// until the reload settles to prevent rapid re-triggering.
    @Published var isSwitchingModel = false

    private var switchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    /// Blocks new selections while a download or model switch is running.
    var isBusy: Bool { isDownloading || isSwitchingModel }

    /// True once at least one whisper model exists on disk.
    var hasLocalModel: Bool { items.contains(where: { $0.isDownloaded }) }

    /// Rescans `directory` and rebuilds the merged catalog + on-disk list.
    func refresh(directory: URL) {
        items = ModelManager.listItems(in: directory)
    }

    /// Rescans and fixes up config so modelPath points at a real file and
    /// vadModelPath at the silero model when present.
    func refreshAndReconcile(directory: URL, store: SettingsStore) {
        refresh(directory: directory)
        if let vad = ModelManager.vadModel(in: directory) {
            store.config.vadModelPath = vad
        }
        // If the current selection isn't downloaded, fall back to the first
        // downloaded model so the server never points at a missing file.
        let selected = items.first { $0.localURL == store.config.modelPath }
        if selected?.isDownloaded != true,
           let firstLocal = items.first(where: { $0.isDownloaded })?.localURL {
            store.config.modelPath = firstLocal
        }
    }

    /// Selects a model. If it's already on disk, just points config at it; if it's
    /// a catalog model that isn't downloaded yet, downloads it (and the VAD model
    /// if missing), then selects it.
    func select(_ item: ModelListItem, store: SettingsStore) {
        if let local = item.localURL {
            guard !isBusy, local != store.config.modelPath else { return }
            store.config.modelPath = local
            // AppDelegate reloads the server off this modelPath change. Lock the
            // list until the server comes back healthy so the user can't queue up
            // a burst of restarts.
            monitorModelSwitch(store: store)
            return
        }
        guard let url = item.downloadURL else { return }
        download(fileName: item.fileName, from: url, statusLabel: item.displayName, store: store)
    }

    /// Locks the model list while the server reloads onto the new model. Waits for
    /// health to drop (reload started) then return (model ready), each bounded by a
    /// timeout so a stuck server can never leave the UI locked forever.
    private func monitorModelSwitch(store: SettingsStore) {
        switchTask?.cancel()
        isSwitchingModel = true
        let manager = WhisperServerManager(config: store.config)
        switchTask = Task {
            // Phase 1: wait up to 3s for the reload to take the server unhealthy.
            for _ in 0..<15 {
                if Task.isCancelled { break }
                if await !manager.healthCheck() { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Phase 2: wait up to 30s for it to report healthy again.
            for _ in 0..<60 {
                if Task.isCancelled { break }
                if await manager.healthCheck() { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            isSwitchingModel = false
        }
    }

    /// Downloads the default whisper model + VAD model, then selects them.
    func downloadDefaults(store: SettingsStore) {
        download(
            fileName: Constants.defaultModelFileName,
            from: Constants.whisperModelDownloadURL,
            statusLabel: "large-v3-turbo",
            store: store
        )
    }

    /// Downloads only the VAD model, for when a whisper model is already selected
    /// and readable on disk and just the VAD model is missing. Unlike
    /// `downloadDefaults`, this never touches `modelPath`, so it doesn't silently
    /// switch the user off whichever model they had selected.
    func downloadVadOnly(store: SettingsStore) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadingFileName = Constants.defaultVadModelFileName
        errorMessage = nil
        downloadProgress = 0
        downloadStatus = "Downloading VAD model…"

        let dir = store.config.modelsDirectory
        let vadDest = dir.appendingPathComponent(Constants.defaultVadModelFileName)

        downloadTask = Task {
            do {
                try await ModelManager.download(from: Constants.vadModelDownloadURL, to: vadDest) { frac in
                    Task { @MainActor in self.downloadProgress = frac }
                }
                try Task.checkCancellation()
                store.config.vadModelPath = vadDest
                refresh(directory: dir)
                finishIdle(status: "Done")
            } catch is CancellationError {
                finishCancelled(modelDest: vadDest)
            } catch {
                if Task.isCancelled {
                    finishCancelled(modelDest: vadDest)
                } else {
                    finishIdle(status: "")
                    errorMessage = "Download failed: \(error.localizedDescription)"
                    AppLogger.shared.log(.error, "VAD model download failed: \(error)")
                }
            }
        }
    }

    /// Cancels an in-flight download; the running Task's cancellation cleans up.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    // Downloads the VAD model first (if missing), then the requested whisper model,
    // reporting combined progress. Selects the model on success.
    private func download(fileName: String, from url: URL, statusLabel: String, store: SettingsStore) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadingFileName = fileName
        errorMessage = nil
        downloadProgress = 0

        let dir = store.config.modelsDirectory
        let modelDest = dir.appendingPathComponent(fileName)
        let vadDest = dir.appendingPathComponent(Constants.defaultVadModelFileName)
        let needsVad = !FileManager.default.fileExists(atPath: vadDest.path)

        downloadTask = Task {
            do {
                if needsVad {
                    downloadStatus = "Downloading VAD model…"
                    try await ModelManager.download(from: Constants.vadModelDownloadURL, to: vadDest) { frac in
                        Task { @MainActor in self.downloadProgress = frac * 0.05 }
                    }
                    try Task.checkCancellation()
                }

                downloadStatus = "Downloading \(statusLabel)…"
                let base = needsVad ? 0.05 : 0.0
                let span = needsVad ? 0.95 : 1.0
                try await ModelManager.download(from: url, to: modelDest) { frac in
                    Task { @MainActor in self.downloadProgress = base + frac * span }
                }

                if needsVad { store.config.vadModelPath = vadDest }
                store.config.modelPath = modelDest
                refresh(directory: dir)
                finishIdle(status: "Done")
            } catch is CancellationError {
                finishCancelled(modelDest: modelDest)
            } catch {
                if Task.isCancelled {
                    finishCancelled(modelDest: modelDest)
                } else {
                    finishIdle(status: "")
                    errorMessage = "Download failed: \(error.localizedDescription)"
                    AppLogger.shared.log(.error, "Model download failed: \(error)")
                }
            }
        }
    }

    private func finishIdle(status: String) {
        isDownloading = false
        downloadingFileName = nil
        downloadStatus = status
    }

    private func finishCancelled(modelDest: URL) {
        finishIdle(status: "")
        downloadProgress = 0
        // Drop partial fragments so a later retry starts clean.
        try? FileManager.default.removeItem(at: modelDest.appendingPathExtension("partial"))
        AppLogger.shared.log(.info, "Model download cancelled")
    }
}
