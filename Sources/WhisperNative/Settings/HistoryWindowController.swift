import AppKit
import AVFoundation
import SwiftUI
import WhisperNativeCore

// MARK: - HistoryWindowController

@MainActor
public final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore

    public init(store: SettingsStore, onOpenSettings: @escaping @MainActor () -> Void) {
        self.store = store
        let view = HistoryView(
            store: store,
            historyStore: TranscriptionHistoryStore.shared,
            onOpenSettings: onOpenSettings
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Transcription History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        // Same activation-policy dance as Settings: force a Dock icon so the
        // window is focusable / Cmd-Tabbable for the LSUIElement app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Clear the auto-assigned first responder so the search field doesn't
        // grab focus on open; it should only focus when the user clicks it.
        // Deferred to the next runloop pass since SwiftUI's hosting view sets
        // its initial responder after showWindow returns.
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        SettingsWindowController.applyBaselineActivationPolicy(store.config)
    }
}

// MARK: - HistoryView

private struct HistoryView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var historyStore: TranscriptionHistoryStore
    let onOpenSettings: @MainActor () -> Void
    @StateObject private var viewModel = HistoryViewModel()
    @State private var searchQuery = ""

    /// Entries matching the current fuzzy query, newest first. An empty query
    /// keeps the full list; otherwise entries are ranked by match score.
    private func filter(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        let needle = FuzzyMatch.needle(for: query)
        return entries
            .compactMap { entry -> (entry: HistoryEntry, score: Int)? in
                // Match across transcript text plus model/language so a query
                // like "pt" or "turbo" narrows the list too.
                let haystack = "\(entry.text) \(entry.modelName) \(entry.language.rawValue)"
                guard let score = FuzzyMatch.score(needle: needle, in: haystack) else { return nil }
                return (entry, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.entry)
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 transcription" : "\(count) transcriptions"
    }

    var body: some View {
        // Computed once per body pass and threaded through the list, count, and
        // empty-state checks so the fuzzy filter doesn't re-run per access.
        let entries = filter(historyStore.entries)
        Group {
            if historyStore.entries.isEmpty {
                ContentUnavailableView(
                    "No transcriptions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Dictated transcripts appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(
                            entry: entry,
                            viewModel: viewModel,
                            store: store,
                            historyStore: historyStore
                        )
                        .listRowInsets(EdgeInsets(
                            top: DesignSystem.Spacing.sm,
                            leading: DesignSystem.Spacing.lg,
                            bottom: DesignSystem.Spacing.sm,
                            trailing: DesignSystem.Spacing.lg
                        ))
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(Color(nsColor: .separatorColor).opacity(0.5))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
                // Animate on count (cheap) rather than mapping ids to an array on
                // every body pass; add/delete is what needs the row transition.
                .animation(DesignSystem.Motion.smooth, value: entries.count)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .safeAreaInset(edge: .top) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text("History")
                        .font(.title2.weight(.bold))
                    MetadataChip(countLabel(entries.count))
                    Spacer()
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    // Cmd-, opens Settings, matching the macOS convention.
                    .keyboardShortcut(",", modifiers: .command)
                }
                HistorySearchField(text: $searchQuery)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onDisappear { viewModel.stopPlayback() }
    }
}

// MARK: - HistorySearchField

/// Rounded search field bound to the History view's fuzzy query, with a leading
/// magnifier and a clear (✕) button that appears once text is entered.
private struct HistorySearchField: View {
    @Binding var text: String
    // Left unfocused on open; the field only gains focus when the user clicks
    // it (the window controller also clears the first responder on show).
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? .primary : .secondary)
                .font(.system(size: 13, weight: .medium))
            TextField("Search transcriptions", text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.control, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.control, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.4),
                        lineWidth: isFocused ? 2 : 1)
        )
        .animation(DesignSystem.Motion.snappy, value: text.isEmpty)
        .animation(DesignSystem.Motion.snappy, value: isFocused)
    }
}

// MARK: - FuzzyMatch

/// Subsequence fuzzy matcher: every query character must appear in order within
/// the target (case-insensitive). Returns a relevance score (higher is better)
/// that rewards contiguous runs and start-of-word matches, or nil if no match.
private enum FuzzyMatch {
    /// Lowercase the query into a needle once, then reuse it across every entry
    /// in a filter pass (the query is constant while entries vary).
    static func needle(for query: String) -> [Character] {
        Array(query.lowercased())
    }

    static func score(needle: [Character], in target: String) -> Int? {
        guard !needle.isEmpty else { return 0 }

        var needleIndex = 0
        var totalScore = 0
        var consecutiveRun = 0
        var previousMatchWasAdjacent = false
        var previousWasLetter = false

        // Single forward pass over the haystack, lowercasing char-by-char rather
        // than materializing a full lowercased [Character] copy of the transcript.
        for rawChar in target {
            if needleIndex == needle.count { break } // needle exhausted; stop early

            let char = Character(rawChar.lowercased())
            let isLetter = char.isLetter

            guard char == needle[needleIndex] else {
                previousMatchWasAdjacent = false
                previousWasLetter = isLetter
                continue
            }

            var charScore = 1
            if previousMatchWasAdjacent {
                consecutiveRun += 1
                charScore += consecutiveRun * 3 // reward contiguous runs
            } else {
                consecutiveRun = 0
            }
            // Bonus for matching at a word boundary (start, or after a separator).
            if !previousWasLetter {
                charScore += 5
            }

            totalScore += charScore
            previousMatchWasAdjacent = true
            previousWasLetter = isLetter
            needleIndex += 1
        }

        return needleIndex == needle.count ? totalScore : nil
    }
}

// MARK: - HistoryRow

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var viewModel: HistoryViewModel
    // Plain refs, not observed: the row only calls into these from button
    // closures, so observing them would invalidate every row on any mutation.
    let store: SettingsStore
    let historyStore: TranscriptionHistoryStore

    @State private var isHovering = false
    @State private var didCopy = false
    // Cached so we don't stat the filesystem on every render/hover/scroll frame.
    // Resolved once when the row appears; refreshed after a delete/rerun below.
    @State private var audioExists = true
    // Expands the transcript from its 3-line clamp to the full text in place.
    @State private var isExpanded = false

    private var isPlaying: Bool { viewModel.playingEntryID == entry.id }
    private var isRerunning: Bool { viewModel.rerunningEntryIDs.contains(entry.id) }

    private var durationLabel: String? {
        guard let seconds = entry.durationSeconds else { return nil }
        return String(format: "%.1fs", seconds)
    }

    var body: some View {
        // Transcript leads (it's a text log); metadata is a quiet footnote below.
        // Actions stay hidden until hover, revealed as a single floating glass
        // strip in the top-right so resting rows read as clean text.
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            transcript
            if let error = viewModel.errorMessages[entry.id] {
                Text(error)
                    .font(DesignSystem.Typography.rowSubtitle)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
            metadataLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) { actions }
        .onHover { hovering in
            withAnimation(DesignSystem.Motion.snappy) { isHovering = hovering }
        }
        .animation(DesignSystem.Motion.smooth, value: isRerunning)
        .animation(DesignSystem.Motion.smooth, value: isPlaying)
        .task(id: entry.id) {
            audioExists = FileManager.default.fileExists(atPath: entry.audioFilePath.path)
        }
        .onChange(of: isRerunning) { _, running in
            // A finished rerun may have (re)written the WAV; re-check once it ends.
            if !running {
                audioExists = FileManager.default.fileExists(atPath: entry.audioFilePath.path)
            }
        }
    }

    // MARK: - Row sections

    @ViewBuilder
    private var transcript: some View {
        if entry.text.isEmpty {
            Text(entry.status == .failed ? "Transcription failed" : "No text")
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
        } else {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(DesignSystem.Motion.smooth) { isExpanded.toggle() }
                }
        }
    }

    // A single dot-separated footnote: state · time · language · model · duration.
    private var metadataLine: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if entry.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption2)
            }
            Text(metadataText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var metadataText: String {
        var parts: [String] = [
            entry.timestamp.formatted(.relative(presentation: .named)),
            entry.language.rawValue.uppercased(),
            entry.modelName,
        ]
        if let durationLabel { parts.append(durationLabel) }
        return parts.joined(separator: "  ·  ")
    }

    // Actions surface only when the row is hovered, or while an action is mid-flight
    // (playing / rerunning) so the user can still stop it after moving the pointer.
    private var actionsVisible: Bool { isHovering || isPlaying || isRerunning }

    @ViewBuilder
    private var actions: some View {
        if actionsVisible {
            HStack(spacing: 2) {
                if !entry.text.isEmpty {
                    GlassIconButton(
                        systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: isExpanded ? "Collapse" : "Expand full text",
                        symbolTransition: true
                    ) {
                        withAnimation(DesignSystem.Motion.smooth) { isExpanded.toggle() }
                    }
                }

                GlassIconButton(
                    systemImage: isPlaying ? "stop.fill" : "play.fill",
                    help: isPlaying ? "Stop" : (audioExists ? "Play" : "Audio file missing"),
                    symbolTransition: true
                ) {
                    if isPlaying { viewModel.stopPlayback() } else { viewModel.play(entry) }
                }
                .disabled(!audioExists)

                GlassIconButton(
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    help: didCopy ? "Copied" : "Copy transcript",
                    tint: didCopy ? .green : nil,
                    symbolTransition: true
                ) {
                    // Match the insertion setting: wrap in <audio> tags when the
                    // user has that enabled, so the clipboard mirrors dictation.
                    let text = store.config.prependAudioTags
                        ? Constants.wrapWithAudioTags(entry.text)
                        : entry.text
                    viewModel.copy(text)
                    showCopyConfirmation()
                }
                .disabled(entry.text.isEmpty)

                if isRerunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                }

                Menu {
                    Button {
                        Task { await viewModel.rerun(entry, store: store, historyStore: historyStore) }
                    } label: {
                        Label("Transcribe again", systemImage: "arrow.clockwise")
                    }
                    .disabled(!audioExists || isRerunning)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.audioFilePath])
                    } label: {
                        Label("Show audio in Finder", systemImage: "folder")
                    }
                    .disabled(!audioExists)

                    Divider()

                    Button(role: .destructive) {
                        viewModel.stopPlaybackIfPlaying(entry.id)
                        withAnimation(DesignSystem.Motion.smooth) {
                            historyStore.delete(id: entry.id)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, 3)
            // The whole strip is one floating Liquid Glass capsule, not four
            // separate pills, so the buttons read as a single unified control.
            .glassEffect(.regular.interactive(), in: .capsule)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
        }
    }

    // MARK: - Copy confirmation micro-interaction

    private func showCopyConfirmation() {
        withAnimation(DesignSystem.Motion.smooth) { didCopy = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(DesignSystem.Motion.smooth) { didCopy = false }
        }
    }
}

// MARK: - GlassIconButton

/// A single glyph inside the floating glass action strip. The strip itself
/// supplies the Liquid Glass surface, so each button stays a plain borderless
/// icon that highlights on hover, tinting on demand (e.g. green copy check).
private struct GlassIconButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color? = nil
    var symbolTransition: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .regular))
                // Quiet by default; the glyph only reaches full contrast when the
                // pointer is over it, so the strip reads as calm until aimed at.
                .foregroundStyle(tint ?? (isHovering ? .primary : .secondary))
                .modifier(SymbolReplace(enabled: symbolTransition))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { hovering in
            if isEnabled { isHovering = hovering }
        }
    }
}

/// Applies the symbol-replace content transition only where a glyph swaps
/// (play/stop, copy/checkmark), leaving static icons untouched.
private struct SymbolReplace: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

// MARK: - HistoryViewModel

/// Owns per-entry rerun/playback state for the History view. Uses a throwaway
/// `WhisperClient` (stateless actor, safe to instantiate) rather than reaching
/// into the app's shared client, mirroring the calibration recorder.
@MainActor
private final class HistoryViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var rerunningEntryIDs: Set<UUID> = []
    @Published var playingEntryID: UUID?
    @Published var errorMessages: [UUID: String] = [:]

    private let whisperClient = WhisperClient()
    private var audioPlayer: AVAudioPlayer?

    // MARK: Playback

    func play(_ entry: HistoryEntry) {
        stopPlayback()
        guard FileManager.default.fileExists(atPath: entry.audioFilePath.path) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: entry.audioFilePath)
            player.delegate = self
            audioPlayer = player
            player.play()
            playingEntryID = entry.id
        } catch {
            errorMessages[entry.id] = "Playback failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "History playback failed: \(error)")
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingEntryID = nil
    }

    func stopPlaybackIfPlaying(_ id: UUID) {
        if playingEntryID == id {
            stopPlayback()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.audioPlayer = nil
            self?.playingEntryID = nil
        }
    }

    // MARK: Copy

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Rerun

    func rerun(_ entry: HistoryEntry, store: SettingsStore, historyStore: TranscriptionHistoryStore) async {
        errorMessages[entry.id] = nil

        guard FileManager.default.fileExists(atPath: entry.audioFilePath.path) else {
            errorMessages[entry.id] = "Audio file missing — cannot rerun."
            return
        }

        let config = store.config
        let backend: any TranscriptionBackend = config.transcriptionEngine == .parakeet
            ? ParakeetBackend.shared
            : whisperClient
        guard await backend.isAvailable() else {
            errorMessages[entry.id] = "whisper-server is not running. Start it from the menu."
            return
        }

        rerunningEntryIDs.insert(entry.id)
        defer { rerunningEntryIDs.remove(entry.id) }

        do {
            let result = try await backend.transcribe(audioFile: entry.audioFilePath, config: config)
            var updated = entry
            updated.text = result.text
            updated.language = result.language
            updated.modelName = config.selectedModelName
            updated.durationSeconds = result.durationSeconds
            updated.status = .success
            historyStore.update(updated)
        } catch {
            var updated = entry
            updated.status = .failed
            historyStore.update(updated)
            errorMessages[entry.id] = "Rerun failed: \(error.localizedDescription)"
            AppLogger.shared.log(.error, "History rerun failed: \(error)")
        }
    }
}
