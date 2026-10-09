import Foundation

/// The engines the user picks between in Settings > General and onboarding,
/// one per engine page in the Settings sidebar. Gemini covers both Gemini
/// engines: choosing it selects Gemini Live or batch Gemini from the
/// Streaming / Batch choice remembered in `Config.geminiStreaming`.
public enum EngineChoice: String, CaseIterable, Identifiable, Sendable {
    case whisper
    case parakeet
    case gemini

    public var id: String { rawValue }

    public init(_ engine: TranscriptionEngine) {
        switch engine {
        case .whisper: self = .whisper
        case .parakeet: self = .parakeet
        case .gemini, .geminiLive: self = .gemini
        }
    }

    /// Plain name, the same as the engine's Settings sidebar page.
    public var name: String {
        switch self {
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        case .gemini: "Gemini"
        }
    }

    /// One-line plain trade-off.
    public var summary: String {
        switch self {
        case .whisper: "Runs on this Mac. Most accurate, about 100 languages."
        case .parakeet: "Runs on this Mac. Fastest, shows a live transcript, 25 European languages."
        case .gemini: "Cloud (Google). Needs an API key and internet, billed per use by Google."
        }
    }

    /// Technical details for the "?" popovers.
    public var details: String {
        switch self {
        case .whisper:
            "whisper.cpp running as a background server, so the model stays warm. Uses the custom vocabulary (words.yml) and an optional initial prompt."
        case .parakeet:
            "NVIDIA Parakeet TDT v3 on the Neural Engine (FluidAudio). The model downloads on first use (~500 MB)."
        case .gemini:
            "Experimental. Gemini 3.5 Transcribe: Live delivery streams audio while you talk (Live API), After recording sends the whole recording once you stop."
        }
    }

    /// What the transcription language does with this engine, one line shown
    /// under the language picker (Settings > Language, onboarding).
    public var languageCaption: String {
        switch self {
        case .whisper: "Whisper transcribes in the language you pick; Auto-detect guesses it per dictation."
        case .parakeet: "Parakeet always auto-detects; the language only narrows which alphabet it uses."
        case .gemini: "Gemini auto-detects; a fixed language is sent as a hint."
        }
    }

    /// The engine this choice selects.
    public func engine(geminiStreaming: Bool) -> TranscriptionEngine {
        switch self {
        case .whisper: .whisper
        case .parakeet: .parakeet
        case .gemini: geminiStreaming ? .geminiLive : .gemini
        }
    }

    /// Why this choice can't be activated right now, nil when it can. Gemini
    /// needs an API key (Keychain or environment).
    public func unavailableReason(keyStatus: GeminiKeyStatus) -> String? {
        guard self == .gemini, !keyStatus.hasKey else { return nil }
        return "Gemini needs an API key. Add one on the Gemini page."
    }

    /// Picker entry: the plain name, plus the reason while unavailable, so a
    /// disabled entry says why where it is seen.
    public func pickerLabel(keyStatus: GeminiKeyStatus) -> String {
        unavailableReason(keyStatus: keyStatus) == nil ? name : "\(name) (needs an API key, add it on the Gemini page)"
    }

    /// Engine to switch to when the user picks `choice`, nil when nothing
    /// changes: the choice is unavailable, or it is the engine already in use
    /// (re-picking Gemini keeps the active Streaming / Batch engine).
    public static func engineToSelect(
        _ choice: EngineChoice,
        current: TranscriptionEngine,
        geminiStreaming: Bool,
        keyStatus: GeminiKeyStatus
    ) -> TranscriptionEngine? {
        guard EngineChoice(current) != choice else { return nil }
        guard choice.unavailableReason(keyStatus: keyStatus) == nil else { return nil }
        return choice.engine(geminiStreaming: geminiStreaming)
    }
}
