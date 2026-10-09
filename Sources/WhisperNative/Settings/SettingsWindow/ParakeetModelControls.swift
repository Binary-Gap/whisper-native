import SwiftUI
import WhisperNativeCore

// MARK: - Parakeet model controls

/// Parakeet's FluidAudio models as shared model rows (download with progress,
/// delete when unused), plus the load state with a Load Now / Retry button
/// once the speech model is on disk. Polls the backend and the model folders
/// every second while visible. Renders bare rows with no `Section`, so callers
/// wrap it (Settings > Parakeet and the onboarding engine step).
struct ParakeetModelControls: View {
    @ObservedObject var store: SettingsStore
    /// Caption for a downloaded model that isn't loaded yet; each caller says
    /// when it loads on its own.
    let downloadedNotLoadedCaption: String

    @State private var snapshot = Snapshot()
    @State private var errorMessage: String?

    /// One poll's view of the backend and the model folders.
    private struct Snapshot {
        var loadState: ParakeetLoadState = .notLoaded
        var speechDownloadFraction: Double?
        var downloading: Set<ParakeetModelKind> = []
        var downloaded: Set<ParakeetModelKind> = []
        var sizeLabels: [ParakeetModelKind: String] = [:]

        var isLoaded: Bool {
            switch loadState {
            case .loading, .ready: true
            case .notLoaded, .failed: false
            }
        }
    }

    var body: some View {
        Group {
            ForEach(ParakeetModelKind.allCases) { kind in
                ModelRow(
                    item: rowItem(for: kind),
                    onDownload: { download(kind) },
                    onDelete: { delete(kind) }
                )
            }
            if snapshot.downloaded.contains(.speech) {
                loadStatusLine
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func rowItem(for kind: ParakeetModelKind) -> ModelRowItem {
        let inUseReason = ModelStorage.parakeetInUseReason(kind, config: store.config, parakeetLoaded: snapshot.isLoaded)
        let isDownloading = snapshot.downloading.contains(kind)
        return ModelRowItem(
            id: kind.id,
            name: kind.displayName,
            subtitle: kind == .vad ? "Silero VAD, trims silence and also powers auto-start when you speak" : nil,
            sizeLabel: snapshot.sizeLabels[kind] ?? kind.approxSizeLabel,
            availability: .resolve(
                isDownloaded: snapshot.downloaded.contains(kind),
                isDownloading: isDownloading,
                downloadFraction: kind == .speech ? snapshot.speechDownloadFraction : nil,
                isInUse: inUseReason != nil
            ),
            deleteBlockedReason: inUseReason,
            downloadBlockedReason: isDownloading ? "Already downloading." : nil
        )
    }

    @ViewBuilder
    private var loadStatusLine: some View {
        switch snapshot.loadState {
        case .notLoaded:
            HStack {
                Label(downloadedNotLoadedCaption, systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
                Spacer()
                loadButton("Load Now")
            }
        case .loading:
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .ready:
            Label("Loaded and ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                loadButton("Retry")
            }
        }
    }

    // Warms the model so the first dictation is instant (fetching anything missing).
    private func loadButton(_ title: String) -> some View {
        Button(title) {
            snapshot.loadState = .loading
            Task {
                do {
                    try await ParakeetBackend.shared.preload()
                } catch {
                    AppLogger.shared.log(.error, "Parakeet preload from Settings or onboarding failed: \(error)")
                }
                await refresh()
            }
        }
    }

    private func download(_ kind: ParakeetModelKind) {
        errorMessage = nil
        snapshot.downloading.insert(kind)
        Task {
            do {
                try await ParakeetBackend.shared.download(kind)
                DownloadNotifier.notifyModelDownloaded(kind.displayName)
            } catch {
                errorMessage = "Download failed: \(error.localizedDescription)"
                AppLogger.shared.log(.error, "Parakeet \(kind.displayName) download failed: \(error)")
            }
            await refresh()
        }
    }

    private func delete(_ kind: ParakeetModelKind) {
        errorMessage = nil
        Task {
            // Re-read the load state so a load that started since the last poll blocks it.
            let loadState = await ParakeetBackend.shared.loadState()
            let isLoaded = loadState == .loading || loadState == .ready
            do {
                try ModelStorage.delete(
                    kind.directory(),
                    inUseReason: ModelStorage.parakeetInUseReason(kind, config: store.config, parakeetLoaded: isLoaded)
                )
            } catch {
                errorMessage = "Delete failed: \(error.localizedDescription)"
                AppLogger.shared.log(.error, "Parakeet \(kind.displayName) delete failed: \(error)")
            }
            await refresh()
        }
    }

    private func refresh() async {
        let backend = ParakeetBackend.shared
        var next = Snapshot()
        next.loadState = await backend.loadState()
        next.speechDownloadFraction = await backend.speechModelDownloadFraction()
        for kind in ParakeetModelKind.allCases {
            if await backend.isDownloading(kind) { next.downloading.insert(kind) }
            if kind.isDownloaded() { next.downloaded.insert(kind) }
        }
        // Folder sizes walk every file, so they're re-read only when the set of
        // downloaded models changes.
        if next.downloaded == snapshot.downloaded {
            next.sizeLabels = snapshot.sizeLabels
        } else {
            for kind in next.downloaded {
                next.sizeLabels[kind] = ModelStorage.sizeLabel(onDisk: kind.directory(), approx: kind.approxSizeLabel)
            }
        }
        snapshot = next
    }
}
