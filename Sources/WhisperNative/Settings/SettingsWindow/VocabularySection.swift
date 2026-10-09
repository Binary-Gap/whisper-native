import AppKit
import SwiftUI
import WhisperNativeCore

// MARK: - Custom vocabulary

/// Engines that read the words file's `vocabulary` section.
enum VocabularyEngine {
    case gemini
    case whisper
}

/// Custom vocabulary section of the Gemini and Whisper pages: read-only view of the
/// words file's `vocabulary` section (terms grouped by key, all languages
/// first, with counts, ignored keys and parse errors) plus an Edit button that
/// adds a key for each of the user's languages and opens the file in the
/// default editor. Updates live while visible (`WordsFileModel`). The
/// Whisper page adds the `Config.whisperUsesVocabulary` toggle on top, dims
/// the terms while it is off, and shows how many terms fit whisper's prompt
/// (`WhisperPrompt`) for the selected language when some don't.
struct VocabularySection: View {
    @ObservedObject var store: SettingsStore
    let engine: VocabularyEngine
    @StateObject private var wordsFile = WordsFileModel()

    /// Whether this engine uses the vocabulary (Gemini always does).
    private var isOn: Bool {
        engine == .gemini || store.config.whisperUsesVocabulary
    }

    var body: some View {
        Section {
            if engine == .whisper {
                LabeledToggle(
                    "Use custom vocabulary",
                    help: "Adds the terms below to Whisper's prompt, after the Initial prompt text. The file is shared with Gemini.",
                    isOn: $store.config.whisperUsesVocabulary
                )
            }

            HStack {
                Text(summary)
                    .foregroundStyle(isOn ? .primary : .secondary)
                Spacer()
                Button("Edit…") { wordsFile.openInEditor(languages: store.config.activeLanguages) }
            }

            switch wordsFile.fileState {
            case .missing:
                EmptyView()
            case .malformed(let reason):
                if isOn {
                    Text("\(wordsFile.fileName) has an error, so no vocabulary is sent: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            case .loaded(let contents):
                ForEach(contents.vocabulary.groups, id: \.scope) { group in
                    groupRow(group)
                        .opacity(isOn ? 1 : 0.4)
                }
                if isOn {
                    ForEach(contents.warnings(for: .vocabulary), id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if engine == .whisper, let fitWarning = whisperFitWarning(contents) {
                        Text(fitWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let errorMessage = wordsFile.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            InfoLabel("Custom vocabulary", info: headerInfo)
        }
        .task { await wordsFile.watch() }
    }

    private var headerInfo: String {
        let file = "File: `\(wordsFile.displayPath)`"
        switch engine {
        case .gemini:
            return "Names, brands and jargon Gemini should recognize, listed in the `vocabulary` section of `\(wordsFile.fileName)` under `all` or under a language (English name or code). A fixed language sends `all` plus its own list, Auto detect sends every list. Best results with up to \(WordsFile.recommendedMaxVocabularyTerms) terms. Changes apply to the next dictation.\n\n\(file)"
        case .whisper:
            return "Names, brands and jargon Whisper should recognize, listed in the `vocabulary` section of `\(wordsFile.fileName)` (the same list Gemini uses) under `all` or under a language (English name or code). A fixed language uses `all` plus its own list, Auto detect every list.\n\nThe terms go at the end of Whisper's prompt, which holds about \(WhisperPrompt.whisperMaxTokens) tokens (a few dozen short terms, fewer with a long Initial prompt). Terms are taken in file order and the rest are left out. Changes apply to the next dictation.\n\n\(file)"
        }
    }

    /// Orange line when the selected language's terms don't all fit whisper's prompt.
    private func whisperFitWarning(_ contents: WordsFile.Contents) -> String? {
        let language = store.config.selectedLanguage
        let prompt = WhisperPrompt.build(config: store.config, vocabulary: contents.vocabulary.words(for: language))
        guard !prompt.droppedTerms.isEmpty else { return nil }
        let total = prompt.includedTerms.count + prompt.droppedTerms.count
        return "Whisper's prompt fits the first \(prompt.includedTerms.count) of \(total) terms for \(language.displayName); the rest are left out."
    }

    private func groupRow(_ group: WordsFile.Group) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(title(of: group.scope))
                Spacer()
                MetadataChip(Self.termCount(group.terms.count))
            }
            if !group.terms.isEmpty {
                SettingsTextBox {
                    ScrollView {
                        Text(group.terms.joined(separator: ", "))
                            .font(.callout)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 72)
                }
            }
        }
    }

    private func title(of scope: WordsFile.Scope) -> String {
        switch scope {
        case .allLanguages: return "All languages"
        case .language(let language): return language.displayName
        }
    }

    private static func termCount(_ count: Int) -> String {
        count == 1 ? "1 term" : "\(count) terms"
    }

    private var summary: String {
        switch wordsFile.fileState {
        case .missing:
            return "No terms"
        case .malformed:
            return "Words file has an error"
        case .loaded(let contents):
            // Auto detect sends every list, so its selection is the whole section.
            let selection = contents.vocabulary.selection(for: .auto)
            let total = selection.terms.count + selection.droppedCount
            if total == 0 { return "No terms" }
            var text = Self.termCount(total)
            if engine == .gemini, selection.droppedCount > 0 {
                text += " (Auto detect sends the first \(WordsFile.maxVocabularyTerms))"
            }
            return text
        }
    }
}
