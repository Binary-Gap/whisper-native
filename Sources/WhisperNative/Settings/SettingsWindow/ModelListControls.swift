import SwiftUI
import WhisperNativeCore

// MARK: - Model list controls

/// The whisper model rows plus download progress, model-switch status and
/// error text. Renders bare rows with no `Section`, so callers wrap it in
/// their own section.
struct ModelListControls: View {
    @ObservedObject var store: SettingsStore
    // The single shared downloader owned by AppDelegate; this view only observes
    // it and routes selections/downloads through it.
    @ObservedObject var modelState: ModelSectionState

    var body: some View {
        Group {
            // A custom row list (not a menu Picker) so the download control can
            // sit flush-right, which a menu Picker collapses.
            ForEach(modelState.items) { item in
                ModelRow(
                    item: item,
                    isSelected: item.id == selectedModelID,
                    isBusy: modelState.isBusy,
                    onSelect: { modelState.select(item, store: store) },
                    onDownload: { modelState.select(item, store: store) }
                )
            }

            if modelState.isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: modelState.downloadProgress) {
                        Text(modelState.downloadStatus).font(.caption)
                    }
                    .progressViewStyle(.linear)
                    Button {
                        modelState.cancelDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel download")
                }
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

    // The currently selected model's id (filename), matched by on-disk path.
    private var selectedModelID: String? {
        modelState.items.first { $0.localURL == store.config.modelPath }?.id
    }
}

// MARK: - Model row

// One row in the Model list. Downloaded (inactive) models are selectable: the
// whole row highlights edge-to-edge on hover and the pointer turns into a hand,
// the same feel as a native list selection. The active one is accented.
// Undownloaded models show their size and a blue download button on the trailing
// edge that only brightens when the pointer is over the button itself, making it
// clear the icon (not the row) is what to click; only that button starts the download.
private struct ModelRow: View {
    let item: ModelListItem
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

    // Hover over the whole row (for the selectable-row highlight) vs. just the
    // download icon (for its brighten-on-hover affordance) are tracked separately.
    @State private var isRowHovering = false
    @State private var isIconHovering = false

    // A downloaded model that isn't the active one can be clicked to activate.
    private var isSelectable: Bool { item.isDownloaded && !isSelected && !isBusy }

    var body: some View {
        HStack(spacing: 8) {
            Text(item.displayName)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(item.isDownloaded ? Color.primary : Color.secondary)

            Spacer(minLength: 8)

            if item.isDownloaded {
                if isSelected {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if isRowHovering {
                    Text("Activate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !item.approxSizeLabel.isEmpty {
                    Text(item.approxSizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.fill")
                        // Muted until the pointer is over the icon, where it lights
                        // up to full-strength blue to invite the click.
                        .foregroundStyle(.tint)
                        .opacity(isIconHovering ? 1 : 0.4)
                        .contentShape(Rectangle())
                        .onHover { isIconHovering = $0 }
                }
                .buttonStyle(.plain)
                .help("Download this model")
                .disabled(isBusy)
            }
        }
        // Fill the row's full width and height, then reclaim the section's default
        // insets so the highlight bleeds edge-to-edge like a real list selection.
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isSelectable && isRowHovering ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        // Small outer inset so the rounded highlight sits within the section
        // rather than bleeding to the very edges.
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        // Hand cursor over a clickable (downloaded, inactive) row.
        .pointerStyle(isSelectable ? .link : .default)
        .onHover { isRowHovering = $0 }
        // Clicking the row selects an already-downloaded model; undownloaded rows
        // only react to their download button.
        .onTapGesture {
            guard isSelectable else { return }
            onSelect()
        }
    }
}
