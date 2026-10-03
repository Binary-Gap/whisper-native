import SwiftUI
import WhisperNativeCore

// MARK: - Gemini API key field

/// SecureField for the Gemini API key, backed by `GeminiAPIKeyStore` (Keychain),
/// never Config. Loads on appear and saves on submit and on focus loss; a blank
/// field deletes the stored key. Renders bare rows with no `Section`, so callers
/// wrap it in their own section.
struct GeminiAPIKeyField: View {
    @State private var apiKey = ""
    @State private var saveError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            SecureField("Gemini API key", text: $apiKey)
                .focused($isFocused)
                .onSubmit(save)
                .onChange(of: isFocused) { _, focused in
                    if !focused { save() }
                }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if apiKey.isEmpty, GeminiAPIKeyStore.environmentKey != nil {
                Text("Using GEMINI_API_KEY from the environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { apiKey = GeminiAPIKeyStore.load() ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) != (GeminiAPIKeyStore.load() ?? "") else { return }
        do {
            try GeminiAPIKeyStore.save(apiKey)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
