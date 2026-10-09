import SwiftUI
import WhisperNativeCore

// MARK: - Gemini key model

/// Published Gemini API key status shared by every view that depends on it
/// (key field, General engine picker, Gemini activation row, onboarding).
/// Keychain writes go through here so all of them update together.
@MainActor
final class GeminiKeyModel: ObservableObject {
    static let shared = GeminiKeyModel()

    @Published private(set) var status: GeminiKeyStatus = .current

    /// Re-reads the Keychain (it can change outside the app).
    func refresh() {
        let latest = GeminiKeyStatus.current
        if latest != status { status = latest }
    }

    func save(_ key: String) throws {
        defer { refresh() }
        try GeminiAPIKeyStore.save(key)
    }

    func remove() throws {
        defer { refresh() }
        try GeminiAPIKeyStore.save("")
    }
}

// MARK: - Gemini API key field

/// SecureField for the Gemini API key, backed by `GeminiAPIKeyStore` (Keychain),
/// never Config. Loads on appear; Return, the Save button and focus loss save
/// a changed key and flash "Saved". Clearing the field (or Remove Key…) asks
/// before deleting the Keychain key; leaving the page with a cleared field
/// keeps the stored key. A status line always shows where the key comes from.
/// Renders bare rows with no `Section`, so callers wrap it in their own section.
struct GeminiAPIKeyField: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var keyModel = GeminiKeyModel.shared
    @State private var apiKey = ""
    // Keychain value as last read, so typing doesn't hit the Keychain.
    @State private var storedKey: String?
    @State private var saveError: String?
    @State private var showsSaved = false
    @State private var savedFlashID = 0
    @State private var isConfirmingRemoval = false
    @FocusState private var isFocused: Bool

    private var commit: GeminiKeyFieldCommit {
        GeminiKeyFieldCommit.resolve(typed: apiKey, stored: storedKey)
    }

    var body: some View {
        Group {
            SecureField("Gemini API key", text: $apiKey)
                .focused($isFocused)
                .onSubmit(commitField)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitField() }
                }

            HStack(spacing: DesignSystem.Spacing.md) {
                statusLine
                Spacer()
                if showsSaved, !isSaveable {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                if keyModel.status == .keychain {
                    Button("Remove Key…") { isConfirmingRemoval = true }
                }
                Button("Save", action: commitField)
                    .disabled(!isSaveable)
            }
        }
        .onAppear {
            keyModel.refresh()
            reloadStoredKey()
        }
        .onDisappear(perform: saveOnLeave)
        .confirmationDialog("Remove the Gemini API key?", isPresented: $isConfirmingRemoval) {
            Button("Remove Key", role: .destructive, action: removeKey)
            Button("Cancel", role: .cancel, action: reloadStoredKey)
        } message: {
            Text("Deletes the key from your Keychain. " + GeminiKeyFieldCommit.removalMessage(
                engine: store.config.transcriptionEngine,
                hasEnvironmentKey: GeminiAPIKeyStore.environmentKey != nil
            ))
        }
    }

    private var isSaveable: Bool {
        if case .save = commit { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        if let saveError {
            Label(saveError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
        } else if keyModel.status.activeEngineWarning(engine: store.config.transcriptionEngine) != nil {
            Label("No API key. Gemini is the active engine, so every dictation fails until you save one.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        } else {
            switch keyModel.status {
            case .missing:
                Label(keyModel.status.label, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            case .keychain:
                Label(keyModel.status.label, systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            case .environment:
                Label(keyModel.status.label, systemImage: "terminal")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private func commitField() {
        switch commit {
        case .unchanged:
            break
        case .save(let key):
            do {
                try keyModel.save(key)
                saveError = nil
                reloadStoredKey()
                flashSaved()
            } catch {
                saveError = error.localizedDescription
            }
        case .confirmRemoval:
            isConfirmingRemoval = true
        }
    }

    // The page is going away, so there is no one left to confirm a removal:
    // a changed key is saved, a cleared field keeps the stored key.
    private func saveOnLeave() {
        guard case .save(let key) = commit else { return }
        try? keyModel.save(key)
    }

    private func removeKey() {
        do {
            try keyModel.remove()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        reloadStoredKey()
    }

    private func reloadStoredKey() {
        storedKey = GeminiAPIKeyStore.load()
        apiKey = storedKey ?? ""
    }

    private func flashSaved() {
        showsSaved = true
        savedFlashID += 1
        let flashID = savedFlashID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if flashID == savedFlashID { showsSaved = false }
        }
    }
}
