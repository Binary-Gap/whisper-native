import SwiftUI
import WhisperNativeCore

// MARK: - Engine captions

extension TranscriptionEngine {
    /// Short name for buttons ("Use Gemini Live").
    var shortName: String {
        switch self {
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        case .gemini: "Gemini"
        case .geminiLive: "Gemini Live"
        }
    }

    /// One-line summary behind the "?" button of each engine's Settings page.
    var caption: String {
        switch self {
        case .whisper:
            "Best accuracy, ~100 languages, custom vocabulary. Runs as a background server so it stays warm."
        case .parakeet:
            "Faster, shows a live transcript while you talk, 25 European languages. Model downloads on first use (~500 MB)."
        case .gemini:
            "Experimental cloud engine: sends audio to Google's Gemini API. Needs an API key and internet, 85+ languages."
        case .geminiLive:
            "Experimental cloud engine: streams audio to Google's Gemini Live API and shows a live transcript while you talk. Needs an API key and internet."
        }
    }
}

// MARK: - Engine page header

/// First row of an engine page: the engine's name with a "?" button holding
/// its explanation, then an "Active" chip when dictation uses one of
/// `engines` or a "Use <engine>" button that selects `engineToUse`. An
/// inactive engine is a normal state, so its "Dictation currently uses X"
/// line is secondary text, not a warning. `unavailableReason` disables the
/// button and shows the reason in orange (Gemini without an API key);
/// `activeWarning` is an orange line shown while the engine is active.
/// Renders a bare row with no `Section`.
struct EngineActivationRow: View {
    @ObservedObject var store: SettingsStore
    let title: String
    let info: String
    let shortName: String
    let engines: Set<TranscriptionEngine>
    let engineToUse: TranscriptionEngine
    var unavailableReason: String?
    var activeWarning: String?

    /// Row for a page that covers a single engine.
    init(store: SettingsStore, engine: TranscriptionEngine) {
        self.init(
            store: store,
            title: engine.displayName,
            info: engine.caption,
            shortName: engine.shortName,
            engines: [engine],
            engineToUse: engine
        )
    }

    init(
        store: SettingsStore,
        title: String,
        info: String,
        shortName: String,
        engines: Set<TranscriptionEngine>,
        engineToUse: TranscriptionEngine,
        unavailableReason: String? = nil,
        activeWarning: String? = nil
    ) {
        self.store = store
        self.title = title
        self.info = info
        self.shortName = shortName
        self.engines = engines
        self.engineToUse = engineToUse
        self.unavailableReason = unavailableReason
        self.activeWarning = activeWarning
    }

    private var isActive: Bool { engines.contains(store.config.transcriptionEngine) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs / 2) {
                InfoLabel(title, info: info)
                    .font(DesignSystem.Typography.rowTitle)
                if isActive {
                    if let activeWarning {
                        Label(activeWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(DesignSystem.Typography.rowSubtitle)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Dictation currently uses \(store.config.transcriptionEngine.shortName).")
                        .font(DesignSystem.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                    if let unavailableReason {
                        Label(unavailableReason, systemImage: "exclamationmark.circle.fill")
                            .font(DesignSystem.Typography.rowSubtitle)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if isActive {
                MetadataChip("Active", systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                // A disabled button shows no tooltip of its own, so the
                // tooltip sits on an enabled wrapper around it.
                HStack(spacing: 0) {
                    Button {
                        store.config.transcriptionEngine = engineToUse
                    } label: {
                        Label("Use \(shortName)", systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(unavailableReason != nil)
                }
                .contentShape(Rectangle())
                .help(unavailableReason ?? "Make \(shortName) the engine every dictation uses")
            }
        }
    }
}
