import SwiftUI
import WhisperNativeCore

// MARK: - Language Tab

/// The transcription language and the user's languages (`LanguageControls`),
/// with a line under the picker saying what the choice does for the active engine.
struct LanguageTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                LanguageControls(
                    store: store,
                    pickerCaption: EngineChoice(store.config.transcriptionEngine).languageCaption
                )
            }
        }
        .formStyle(.grouped)
    }
}
