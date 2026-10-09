import SwiftUI
import WhisperNativeCore

// MARK: - Language controls

/// The transcription language picker, then the user's languages it picks from
/// (shown as "Your languages", one row each with a remove button) and a search
/// field that adds more. The cycle hotkey steps through them in the listed order.
/// Renders bare rows with no `Section`, so callers wrap it in their own section.
/// `pickerCaption`, when set, shows as a secondary line right under the picker.
struct LanguageControls: View {
    @ObservedObject var store: SettingsStore
    var pickerCaption: String? = nil

    @State private var query = ""

    // Results past this count are summarized so the list stays short; typing
    // more narrows them.
    private static let maxVisibleResults = 8

    private var results: [Language] {
        ActiveLanguages.addable(matching: query, active: store.config.activeLanguages)
    }

    private func add(_ language: Language) {
        store.config.activeLanguages = ActiveLanguages.adding(language, to: store.config.activeLanguages)
        query = ""
    }

    private func remove(_ language: Language) {
        let updated = ActiveLanguages.removing(
            language,
            from: store.config.activeLanguages,
            selected: store.config.selectedLanguage
        )
        store.config.activeLanguages = updated.active
        store.config.selectedLanguage = updated.selected
    }

    var body: some View {
        Group {
            Picker("Transcription language", selection: $store.config.selectedLanguage) {
                ForEach(store.config.activeLanguages) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            if let pickerCaption {
                Text(pickerCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            InfoLabel("Your languages", info: "The languages you dictate in. The transcription language is one of them, and the cycle language hotkey steps through them in this order.")

            ForEach(store.config.activeLanguages) { language in
                activeRow(language)
            }

            addField

            let visibleResults = results.prefix(Self.maxVisibleResults)
            ForEach(Array(visibleResults)) { language in
                resultRow(language)
            }
            if results.count > visibleResults.count {
                Text("\(results.count - visibleResults.count) more, keep typing to narrow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No other language matches \"\(query)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private func activeRow(_ language: Language) -> some View {
        let removable = ActiveLanguages.canRemove(language, from: store.config.activeLanguages)
        return HStack {
            Text(language.displayName)
            Spacer()
            if language != .auto {
                MetadataChip(language.displayCode)
            }
            Button {
                remove(language)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(removable ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!removable)
            .help(removable ? "Remove \(language.displayName)" : "Keep at least one language")
        }
    }

    // Enter adds the top result; Escape clears the search.
    private var addField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Add language", text: $query, prompt: Text("Add a language: type its name or code"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit {
                    if let first = results.first { add(first) }
                }
                .onExitCommand { query = "" }
        }
    }

    private func resultRow(_ language: Language) -> some View {
        Button {
            add(language)
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(language.displayName)
                Spacer()
                MetadataChip(language.displayCode)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add \(language.displayName)")
    }
}
