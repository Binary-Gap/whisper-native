import SwiftUI
import WhisperNativeCore

// MARK: - Language controls

/// The transcription language picker plus the list of languages the cycle
/// hotkey steps through. Renders bare rows with no `Section`, so callers wrap
/// it in their own section.
struct LanguageControls: View {
    @ObservedObject var store: SettingsStore

    // Enabling appends to the cycle, so the order the user ticks languages in is
    // the order the hotkey steps through them.
    private func cycleMembership(_ language: Language) -> Binding<Bool> {
        Binding(
            get: { store.config.cycleLanguages.contains(language) },
            set: { isOn in
                store.config.cycleLanguages.removeAll { $0 == language }
                if isOn { store.config.cycleLanguages.append(language) }
            }
        )
    }

    var body: some View {
        Group {
            Picker("Transcription language", selection: $store.config.selectedLanguage) {
                ForEach(Language.all) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)

            DisclosureGroup("Languages in the cycle hotkey (\(store.config.cycleLanguages.count))") {
                ForEach(Language.all) { language in
                    Toggle(language.displayName, isOn: cycleMembership(language))
                }
            }
        }
    }
}
