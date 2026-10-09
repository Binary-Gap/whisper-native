import Foundation

/// Where the Gemini API key comes from, as Settings and onboarding show it.
/// The Keychain wins over the `GEMINI_API_KEY` environment fallback, matching
/// `GeminiAPIKeyStore.resolvedKey`.
public enum GeminiKeyStatus: Equatable, Sendable {
    case missing
    case keychain
    case environment

    public static func resolve(keychainKey: String?, environmentKey: String?) -> GeminiKeyStatus {
        if isNonBlank(keychainKey) { return .keychain }
        if isNonBlank(environmentKey) { return .environment }
        return .missing
    }

    /// Current status from the Keychain and the process environment.
    public static var current: GeminiKeyStatus {
        resolve(keychainKey: GeminiAPIKeyStore.load(), environmentKey: GeminiAPIKeyStore.environmentKey)
    }

    public var hasKey: Bool { self != .missing }

    /// Status line under the key field.
    public var label: String {
        switch self {
        case .missing: "No API key. Gemini can't be used until you add one."
        case .keychain: "Key saved in your Keychain."
        case .environment: "Using GEMINI_API_KEY from the environment."
        }
    }

    /// Warning shown while a Gemini engine is active without any key (the key
    /// was removed after Gemini was selected). The engine stays selected and
    /// each dictation fails with `AppError.geminiAPIKeyMissing` until a key is
    /// added; nil when there is nothing to warn about.
    public func activeEngineWarning(engine: TranscriptionEngine) -> String? {
        guard !hasKey, engine == .gemini || engine == .geminiLive else { return nil }
        return "Gemini is the active engine but has no API key, so dictation fails until you add one on the Gemini page."
    }

    private static func isNonBlank(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// What committing the key field (Return, Save, focus loss) does with the
/// typed text, given the key stored in the Keychain.
public enum GeminiKeyFieldCommit: Equatable, Sendable {
    /// Text matches the stored key (trimmed): nothing to do.
    case unchanged
    /// Store this trimmed key.
    case save(String)
    /// The field was cleared while a Keychain key exists: ask before deleting.
    case confirmRemoval

    public static func resolve(typed: String, stored: String?) -> GeminiKeyFieldCommit {
        let trimmedTyped = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStored = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedTyped == trimmedStored { return .unchanged }
        if trimmedTyped.isEmpty { return .confirmRemoval }
        return .save(trimmedTyped)
    }

    /// Message of the "Remove the Gemini API key?" confirmation: what happens
    /// once the Keychain key is gone.
    public static func removalMessage(engine: TranscriptionEngine, hasEnvironmentKey: Bool) -> String {
        if hasEnvironmentKey {
            return "Gemini will use GEMINI_API_KEY from the environment instead."
        }
        if engine == .gemini || engine == .geminiLive {
            return "Gemini stays the active engine, but every dictation fails until you add a key."
        }
        return "Gemini can't be selected again until you add a key."
    }
}
