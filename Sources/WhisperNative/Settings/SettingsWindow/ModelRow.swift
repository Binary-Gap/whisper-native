import SwiftUI
import WhisperNativeCore

// MARK: - Model row item

/// One model as a row shows it, built by each engine's model list (whisper
/// models, whisper VAD, Parakeet's FluidAudio models).
struct ModelRowItem: Identifiable {
    let id: String
    let name: String
    /// Short line under the name (speed/accuracy hint, what the model is for).
    var subtitle: String?
    /// Shows a "Recommended" chip next to the name.
    var isRecommended = false
    /// Real size once on disk, approximate download size before.
    let sizeLabel: String
    let availability: ModelAvailability
    /// Why Delete is disabled (in use, or another download / switch running);
    /// shown as the Delete button's tooltip. Nil when the model can be deleted.
    var deleteBlockedReason: String?
    /// Why Download is disabled; shown as its tooltip. Nil when it can start.
    var downloadBlockedReason: String?
    /// Why Use is disabled (a download or model switch running); nil when it
    /// can be clicked.
    var useBlockedReason: String?
}

// MARK: - Model row

/// The shared model row for the Whisper and Parakeet pages and onboarding:
/// name (with a "Recommended" chip and a hint line when given), size, state
/// (not downloaded / downloading with progress / downloaded / in use) and a
/// Download or Delete button. Rows of a list where one model is picked
/// (`onUse` set) also get a Use button on downloaded models that aren't in
/// use; finishing a download never picks the model. Delete asks for
/// confirmation. Renders a bare row, so callers place it inside their own
/// `Section`.
struct ModelRow: View {
    let item: ModelRowItem
    let onDownload: () -> Void
    let onDelete: () -> Void
    /// Makes this downloaded model the one in use; nil hides the Use button.
    var onUse: (() -> Void)?
    /// Cancels the running download; nil hides the cancel button.
    var onCancelDownload: (() -> Void)?

    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(item.name)
                        .fontWeight(item.availability == .inUse ? .semibold : .regular)
                        .foregroundStyle(item.availability.isOnDisk ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isRecommended {
                        MetadataChip("Recommended", systemImage: "star.fill", tint: .accentColor)
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Text(item.sizeLabel)
                .font(DesignSystem.Typography.metadata)
                .foregroundStyle(.secondary)

            stateView
                .frame(minWidth: 84, alignment: .trailing)

            actionButtons
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Delete \(item.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Frees \(item.sizeLabel) on disk. You can download it again later.")
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch item.availability {
        case .notDownloaded:
            Text("Not downloaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: DesignSystem.Spacing.xs) {
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 60)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(DesignSystem.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .downloaded:
            Text("Downloaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .inUse:
            Label("In use", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.availability {
        case .notDownloaded:
            tooltipWrapped(item.downloadBlockedReason ?? (onUse == nil ? "Download this model" : "Download this model. Click Use once it's downloaded to switch to it.")) {
                Button("Download", action: onDownload)
                    .controlSize(.small)
                    .disabled(item.downloadBlockedReason != nil)
            }
        case .downloading:
            if let onCancelDownload {
                Button(action: onCancelDownload) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
            }
        case .downloaded, .inUse:
            if let onUse, item.availability == .downloaded {
                tooltipWrapped(item.useBlockedReason ?? "Use this model") {
                    Button("Use", action: onUse)
                        .controlSize(.small)
                        .disabled(item.useBlockedReason != nil)
                }
            }
            tooltipWrapped(item.deleteBlockedReason ?? "Delete this model from disk") {
                Button("Delete", role: .destructive) { isConfirmingDelete = true }
                    .controlSize(.small)
                    .disabled(item.deleteBlockedReason != nil)
            }
        }
    }

    // A disabled control shows no tooltip of its own, so the tooltip sits on an
    // enabled wrapper around it.
    private func tooltipWrapped(_ help: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) { content() }
            .contentShape(Rectangle())
            .help(help)
    }
}
