import SwiftUI
import WhisperNativeCore

// MARK: - Model list controls

/// The whisper model rows, smallest first (download progress inside the
/// downloading row, Use on downloaded models that aren't in use, a
/// "Recommended" chip and a speed/accuracy hint per catalog model),
/// model-switch status and error text. Renders bare rows with no `Section`,
/// so callers wrap it in their own section.
struct ModelListControls: View {
    @ObservedObject var store: SettingsStore
    // The single shared downloader owned by AppDelegate; this view only observes
    // it and routes uses/downloads/deletes through it.
    @ObservedObject var modelState: ModelSectionState

    var body: some View {
        Group {
            ForEach(modelState.items) { item in
                ModelRow(
                    item: rowItem(for: item),
                    onDownload: { modelState.download(item, store: store) },
                    onDelete: {
                        guard let url = item.localURL else { return }
                        modelState.delete(url, inUseReason: ModelStorage.whisperModelInUseReason(url, config: store.config), store: store)
                    },
                    onUse: { modelState.use(item, store: store) },
                    onCancelDownload: { modelState.cancelDownload() }
                )
            }

            if modelState.isSwitchingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Switching model…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let err = modelState.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func rowItem(for item: ModelListItem) -> ModelRowItem {
        let inUseReason = item.localURL.flatMap { ModelStorage.whisperModelInUseReason($0, config: store.config) }
        return ModelRowItem(
            id: item.id,
            name: item.displayName,
            subtitle: item.hint,
            isRecommended: item.isRecommended,
            sizeLabel: ModelStorage.sizeLabel(onDisk: item.localURL, approx: item.approxSizeLabel),
            availability: .resolve(
                isDownloaded: item.isDownloaded,
                isDownloading: modelState.downloadingFileName == item.fileName,
                downloadFraction: modelState.downloadProgress,
                isInUse: inUseReason != nil
            ),
            deleteBlockedReason: inUseReason ?? modelState.busyReason,
            downloadBlockedReason: modelState.busyReason,
            useBlockedReason: modelState.busyReason
        )
    }
}

// MARK: - VAD model controls

/// The whisper VAD (silero) model as a single row: download, delete when not
/// selected, and Use once downloaded if it isn't the selected one. Renders a
/// bare row with no `Section`.
struct VadModelControls: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var modelState: ModelSectionState

    private var vadURL: URL {
        modelState.vadModelURL
            ?? store.config.modelsDirectory.appendingPathComponent(Constants.defaultVadModelFileName)
    }

    var body: some View {
        let url = vadURL
        let inUseReason = ModelStorage.whisperVadInUseReason(url, config: store.config)
        let isDownloaded = modelState.vadModelURL != nil
        ModelRow(
            item: ModelRowItem(
                id: url.lastPathComponent,
                name: "Silence detection (Whisper)",
                subtitle: "\(ModelFile(url: url, sizeBytes: 0).displayName), trims silence before whisper transcribes",
                sizeLabel: ModelStorage.sizeLabel(onDisk: modelState.vadModelURL, approx: "~1 MB"),
                availability: .resolve(
                    isDownloaded: isDownloaded,
                    isDownloading: modelState.downloadingFileName == url.lastPathComponent,
                    downloadFraction: modelState.downloadProgress,
                    isInUse: inUseReason != nil
                ),
                deleteBlockedReason: inUseReason ?? modelState.busyReason,
                downloadBlockedReason: modelState.busyReason,
                useBlockedReason: modelState.busyReason
            ),
            onDownload: { modelState.downloadVadOnly(store: store, notifiesWhenDone: true) },
            onDelete: {
                modelState.delete(url, inUseReason: ModelStorage.whisperVadInUseReason(url, config: store.config), store: store)
            },
            onUse: { store.config.vadModelPath = url },
            onCancelDownload: { modelState.cancelDownload() }
        )
    }
}
