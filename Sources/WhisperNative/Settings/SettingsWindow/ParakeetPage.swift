import SwiftUI
import WhisperNativeCore

// MARK: - Parakeet page

/// Settings > Engines > Parakeet: activation and the in-process models'
/// download / delete / load state, plus a line saying it has no custom
/// vocabulary.
struct ParakeetPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                EngineActivationRow(store: store, engine: .parakeet)

                Text("Parakeet doesn't support custom vocabulary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ParakeetModelControls(store: store, downloadedNotLoadedCaption: "Downloaded, loads when Parakeet is the active engine")
            } header: {
                InfoLabel("Models", info: "Parakeet auto-detects among 25 European languages (the language setting only narrows its alphabet) and removes filler sounds (uh, um). It has no prompt or voice calibration.\n\nBoth models are stored in `~/Library/Application Support/FluidAudio/Models`; the Silero VAD also powers auto-start when you speak.")
            }
        }
        .formStyle(.grouped)
    }
}
