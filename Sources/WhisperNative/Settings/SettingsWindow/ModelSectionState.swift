import Foundation
import SwiftUI
import WhisperNativeCore

/// Drives the Whisper models and VAD sections: lists all known models
/// (catalog + folder scan) and the VAD model, downloads a chosen or default
/// model + the VAD model, deletes unused ones, and keeps the config's
/// modelPath/vadModelPath valid. A download only puts the file on disk: the
/// model in use changes through `use(_:store:)` (the row's Use button), or
/// for the recommended model the user agreed to download and use
/// (`downloadDefaults`).
@MainActor
public final class ModelSectionState: ObservableObject {
    @Published var items: [ModelListItem] = []
    /// The whisper VAD (silero) `.bin` in the models folder, if downloaded.
    @Published var vadModelURL: URL?
    @Published var isDownloading = false
    /// Progress (0...1) of the file in `downloadingFileName`.
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

    /// Tooltip for row buttons disabled by `isBusy`; nil when idle.
    var busyReason: String? {
        if isDownloading { return "Wait for the running download to finish." }
        if isSwitchingModel { return "Wait for the model switch to finish." }
        return nil
    }

    /// True once at least one whisper model exists on disk.
    var hasLocalModel: Bool { items.contains(where: { $0.isDownloaded }) }

    /// Rescans `directory` and rebuilds the merged catalog + on-disk list.
    func refresh(directory: URL) {
        items = ModelManager.listItems(in: directory)
        vadModelURL = ModelManager.vadModel(in: directory)
    }

    /// Deletes a model file from the models folder and rescans it. Refuses a
    /// model in use (`inUseReason`) and while a download or switch is running.
    func delete(_ url: URL, inUseReason: String?, store: SettingsStore) {
        guard !isBusy else { return }
        errorMessage = nil
        do {
            try ModelStorage.delete(url, inUseReason: inUseReason)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "Model delete failed for \(url.lastPathComponent): \(error)")
        }
        refresh(directory: store.config.modelsDirectory)
    }

    /// Rescans and points vadModelPath at the silero model when present.
    /// With `fallBackToDownloadedModel`, a selected model that isn't on disk is
    /// replaced by a downloaded one (the recommended model when it's there, else
    /// the smallest), so the server never points at a
    /// missing file; AppDelegate passes it when Whisper is about to start and
    /// for a models-folder change. Settings and onboarding only display, so a
    /// model downloaded there stays unused until its Use button.
    func refreshAndReconcile(directory: URL, store: SettingsStore, fallBackToDownloadedModel: Bool) {
        refresh(directory: directory)
        if let vad = ModelManager.vadModel(in: directory) {
            store.config.vadModelPath = vad
        }
        guard fallBackToDownloadedModel else { return }
        let selected = items.first { $0.localURL == store.config.modelPath }
        if selected?.isDownloaded != true, let fallback = ModelManager.fallbackModel(in: items) {
            store.config.modelPath = fallback
        }
    }

    /// Makes a downloaded model the one Whisper uses (the row's Use button).
    func use(_ item: ModelListItem, store: SettingsStore) {
        guard let local = item.localURL, !isBusy, local != store.config.modelPath else { return }
        store.config.modelPath = local
        // AppDelegate reloads the server off this modelPath change. Lock the
        // list until the server comes back healthy so the user can't queue up
        // a burst of restarts. The daemon is down while another engine is
        // active, so there's nothing to wait for then.
        if store.config.transcriptionEngine == .whisper {
            monitorModelSwitch(store: store)
        }
    }

    /// Downloads a catalog model (and the VAD model if missing) without
    /// changing the model in use.
    func download(_ item: ModelListItem, store: SettingsStore) {
        guard item.localURL == nil, let url = item.downloadURL else { return }
        download(fileName: item.fileName, from: url, statusLabel: item.displayName, selectsWhenDone: false, store: store)
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

    /// Downloads the recommended whisper model + VAD model, then selects them.
    /// Only for the download the user just agreed to in AppDelegate's "Download
    /// a Whisper model?" prompt, which asks to download and use it.
    func downloadDefaults(store: SettingsStore) {
        let model = ModelManager.recommendedModel
        download(
            fileName: model.fileName,
            from: model.downloadURL,
            statusLabel: model.displayName,
            selectsWhenDone: true,
            store: store
        )
    }

    /// Downloads only the VAD model, for when a whisper model is already selected
    /// and readable on disk and just the VAD model is missing. Never touches
    /// `modelPath`. `notifiesWhenDone` posts the "downloaded" notification (the
    /// VAD row's Download button), skipped for the automatic repair download.
    func downloadVadOnly(store: SettingsStore, notifiesWhenDone: Bool = false) {
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
                if notifiesWhenDone {
                    DownloadNotifier.notifyModelDownloaded(ModelFile(url: vadDest, sizeBytes: 0).displayName)
                }
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
    // each reporting its own progress under `downloadingFileName`. Selects the
    // model on success only with `selectsWhenDone`; posts the "downloaded"
    // notification either way (DownloadNotifier skips it while the app is frontmost).
    private func download(fileName: String, from url: URL, statusLabel: String, selectsWhenDone: Bool, store: SettingsStore) {
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
                    downloadingFileName = Constants.defaultVadModelFileName
                    downloadStatus = "Downloading VAD model…"
                    try await ModelManager.download(from: Constants.vadModelDownloadURL, to: vadDest) { frac in
                        Task { @MainActor in self.downloadProgress = frac }
                    }
                    try Task.checkCancellation()
                    downloadingFileName = fileName
                    downloadProgress = 0
                }

                downloadStatus = "Downloading \(statusLabel)…"
                try await ModelManager.download(from: url, to: modelDest) { frac in
                    Task { @MainActor in
                        // A VAD-phase callback landing late must not move this file's bar.
                        guard self.downloadingFileName == fileName else { return }
                        self.downloadProgress = frac
                    }
                }

                if needsVad { store.config.vadModelPath = vadDest }
                if selectsWhenDone { store.config.modelPath = modelDest }
                refresh(directory: dir)
                finishIdle(status: "Done")
                let isInUse = ModelStorage.whisperModelInUseReason(modelDest, config: store.config) != nil
                DownloadNotifier.notifyModelDownloaded(
                    statusLabel,
                    detail: isInUse ? "Whisper will use it." : "Click Use on the Whisper settings page to switch to it."
                )
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
