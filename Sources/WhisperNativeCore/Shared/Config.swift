import Foundation

/// A single modifier key that toggles dictation when tapped. These keys can't be
/// registered as standard shortcuts (a lone modifier isn't a valid Carbon
/// hotkey), so they're captured via a CGEventTap in HotkeyManager instead.
public enum ToggleModifierKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    /// Bind toggleDictation to a chord shortcut recorded via KeyboardShortcuts
    /// instead of a lone modifier. The CGEventTap ignores this case.
    case custom
    case fn
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    public var id: String { rawValue }

    /// Human-readable name shown in the settings picker.
    public var displayName: String {
        switch self {
        case .none: "Off"
        case .fn: "Fn (🌐)"
        case .leftOption: "Left Option (⌥)"
        case .rightOption: "Right Option (⌥)"
        case .leftCommand: "Left Command (⌘)"
        case .rightCommand: "Right Command (⌘)"
        case .leftControl: "Left Control (⌃)"
        case .rightControl: "Right Control (⌃)"
        case .leftShift: "Left Shift (⇧)"
        case .rightShift: "Right Shift (⇧)"
        case .custom: "Custom shortcut…"
        }
    }

    /// Physical keycode (kVK_*) of the key. nil for Fn, which is detected by its
    /// flag bit alone since it has no distinct virtual keycode on flagsChanged.
    public var keyCode: Int64? {
        switch self {
        case .none, .fn, .custom: nil
        case .leftOption: 0x3A    // kVK_Option
        case .rightOption: 0x3D   // kVK_RightOption
        case .leftCommand: 0x37   // kVK_Command
        case .rightCommand: 0x36  // kVK_RightCommand
        case .leftControl: 0x3B   // kVK_Control
        case .rightControl: 0x3E  // kVK_RightControl
        case .leftShift: 0x38     // kVK_Shift
        case .rightShift: 0x3C    // kVK_RightShift
        }
    }

    /// The CGEventFlags mask bit that is set while this key is held. Used to
    /// detect the key-down edge (flag transitions off → on). Zero for cases the
    /// CGEventTap doesn't handle (.none, .custom).
    public var flagMask: UInt64 {
        switch self {
        case .none, .custom: 0
        case .fn: 0x0000000000800000            // NX_SECONDARYFN
        case .leftOption, .rightOption: 0x00080000   // NX_ALTERNATEMASK
        case .leftCommand, .rightCommand: 0x00100000 // NX_COMMANDMASK
        case .leftControl, .rightControl: 0x00040000 // NX_CONTROLMASK
        case .leftShift, .rightShift: 0x00020000     // NX_SHIFTMASK
        }
    }
}

/// How the cancel-transcription shortcut is bound. Escape can't be shown by the
/// KeyboardShortcuts recorder (it swallows Escape to cancel its own capture), so
/// it's offered as an explicit picker option and applied to the shortcut binding
/// programmatically. `.custom` lets the user record any other chord.
public enum CancelKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case escape
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .escape: "Escape (⎋)"
        case .custom: "Custom shortcut…"
        }
    }
}

/// Speech-to-text engine used for dictation. Whisper runs in the whisper-server
/// launchd daemon; Parakeet (TDT v3 via FluidAudio) runs in-process on the
/// Neural Engine; Gemini (experimental) sends the finished recording to Google's
/// Gemini API; Gemini Live (experimental) streams audio to Gemini's Live API
/// while recording. The whisper daemon is booted out while a non-whisper engine
/// is selected.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case whisper
    case parakeet
    case gemini
    case geminiLive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whisper: "Whisper (whisper.cpp)"
        case .parakeet: "Parakeet TDT v3 (Neural Engine)"
        case .gemini: "Gemini 3.5 Transcribe (cloud)"
        case .geminiLive: "Gemini 3.5 Transcribe Live (cloud, streaming)"
        }
    }
}

/// Gemini Live transcription style (`inputAudioTranscription.mode`). Verbatim
/// keeps every word as spoken; Smart drops disfluencies, resolves spoken
/// self-corrections and formats lists, numbers and punctuation.
public enum GeminiLiveMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case verbatim = "VERBATIM"
    case smart = "SMART"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .smart: "Smart"
        }
    }
}

public struct Config: Codable, Sendable {
    public var transcriptionEngine: TranscriptionEngine
    public var selectedLanguage: Language
    /// Languages the cycle hotkey steps through, in order.
    public var cycleLanguages: [Language]
    /// Folder scanned for .bin whisper models. User-selectable; defaults to the
    /// app-owned App Support models directory.
    public var modelsDirectory: URL
    /// Currently selected whisper model file (lives inside modelsDirectory).
    public var modelPath: URL
    public var vadModelPath: URL?
    /// CoreAudio device UID of the preferred input device. UID (not name) survives
    /// reconnects/renames; nil means use the system default input device.
    public var inputDeviceUID: String?
    public var autoPasteWhenSameApp: Bool
    public var normalizeAudio: Bool
    public var noiseReduction: Int
    public var soundFeedback: Bool
    public var soundVolume: Float
    /// Pause Apple Music while recording and resume it afterwards (only when
    /// it was playing at recording start).
    public var pauseMusicWhileRecording: Bool
    public var recordingIndicatorEnabled: Bool
    public var prependAudioTags: Bool
    public var autoSubmitInTerminal: Bool
    /// Press Return after an auto-paste into any app other than iTerm2.
    public var autoSubmitInOtherApps: Bool
    public var translateToEnglish: Bool
    /// Wrap the transcript to `lineWrapWidth` characters, breaking on word
    /// boundaries (whisper-server max_len + split_on_word). Off = raw text.
    public var lineWrapEnabled: Bool
    /// Target max characters per line when `lineWrapEnabled`. Clamped 20...100.
    public var lineWrapWidth: Int
    /// Insert a newline after each sentence-ending punctuation (. ! ?) so every
    /// sentence starts on its own line. Applied as post-processing on the
    /// transcript, independent of `lineWrapEnabled`.
    public var sentencePerLine: Bool
    public var launchAtLogin: Bool
    public var prompt: String
    public var recordingTimeoutSeconds: Int
    public var voiceCalibrationEnabled: Bool
    public var voiceCalibrationSampleText: String
    /// Single modifier key that toggles dictation on tap via a CGEventTap. These
    /// keys can't be captured by the standard shortcut recorder, so they're
    /// exposed as a dedicated picker (.none disables the feature).
    public var toggleModifierKey: ToggleModifierKey
    /// How the cancel-transcription shortcut is bound. `.escape` uses the Escape
    /// key (applied to the shortcut binding programmatically); `.custom` lets the
    /// user record any chord via the standard recorder.
    public var cancelKey: CancelKey
    /// When true, the app shows a Dock icon and appears in Cmd-Tab (.regular
    /// activation policy). When false it stays a menu-bar-only agent (.accessory),
    /// except while the Settings window is open, which forces a Dock icon so the
    /// window is Cmd-Tabbable.
    public var showDockIcon: Bool
    /// Onboarding version the user has completed (0 = never). Compared against
    /// `Onboarding.currentVersion` to decide whether to show it again.
    public var onboardingCompletedVersion: Int
    /// Transcription style for the Gemini Live engine.
    public var geminiLiveMode: GeminiLiveMode

    public init(
        transcriptionEngine: TranscriptionEngine = .whisper,
        selectedLanguage: Language = .auto,
        cycleLanguages: [Language] = Config.defaultCycleLanguages(),
        modelsDirectory: URL = Constants.defaultModelsDirectory,
        modelPath: URL = Constants.defaultModelPath,
        vadModelPath: URL? = Constants.defaultVadModelPath,
        inputDeviceUID: String? = nil,
        autoPasteWhenSameApp: Bool = true,
        normalizeAudio: Bool = true,
        noiseReduction: Int = 0,
        soundFeedback: Bool = true,
        soundVolume: Float = 0.5,
        pauseMusicWhileRecording: Bool = false,
        recordingIndicatorEnabled: Bool = true,
        prependAudioTags: Bool = false,
        autoSubmitInTerminal: Bool = false,
        autoSubmitInOtherApps: Bool = false,
        translateToEnglish: Bool = false,
        lineWrapEnabled: Bool = false,
        lineWrapWidth: Int = 60,
        sentencePerLine: Bool = false,
        launchAtLogin: Bool = false,
        prompt: String = "",
        recordingTimeoutSeconds: Int = 300,
        voiceCalibrationEnabled: Bool = false,
        voiceCalibrationSampleText: String = "",
        toggleModifierKey: ToggleModifierKey = .fn,
        cancelKey: CancelKey = .escape,
        showDockIcon: Bool = false,
        onboardingCompletedVersion: Int = 0,
        geminiLiveMode: GeminiLiveMode = .smart
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.selectedLanguage = selectedLanguage
        self.cycleLanguages = cycleLanguages
        self.modelsDirectory = modelsDirectory
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
        self.inputDeviceUID = inputDeviceUID
        self.autoPasteWhenSameApp = autoPasteWhenSameApp
        self.normalizeAudio = normalizeAudio
        self.noiseReduction = noiseReduction
        self.soundFeedback = soundFeedback
        self.soundVolume = soundVolume
        self.pauseMusicWhileRecording = pauseMusicWhileRecording
        self.recordingIndicatorEnabled = recordingIndicatorEnabled
        self.prependAudioTags = prependAudioTags
        self.autoSubmitInTerminal = autoSubmitInTerminal
        self.autoSubmitInOtherApps = autoSubmitInOtherApps
        self.translateToEnglish = translateToEnglish
        self.lineWrapEnabled = lineWrapEnabled
        self.sentencePerLine = sentencePerLine
        self.lineWrapWidth = lineWrapWidth
        self.launchAtLogin = launchAtLogin
        self.prompt = prompt
        self.recordingTimeoutSeconds = recordingTimeoutSeconds
        self.voiceCalibrationEnabled = voiceCalibrationEnabled
        self.voiceCalibrationSampleText = voiceCalibrationSampleText
        self.toggleModifierKey = toggleModifierKey
        self.cancelKey = cancelKey
        self.showDockIcon = showDockIcon
        self.onboardingCompletedVersion = onboardingCompletedVersion
        self.geminiLiveMode = geminiLiveMode
    }

    // Custom decoder: tolerate configs persisted before a field existed by
    // falling back to the field's default instead of failing the whole decode
    // (which would wipe every user setting back to defaults).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        transcriptionEngine = try container.decodeIfPresent(TranscriptionEngine.self, forKey: .transcriptionEngine) ?? d.transcriptionEngine
        selectedLanguage = try container.decodeIfPresent(Language.self, forKey: .selectedLanguage) ?? d.selectedLanguage
        // Unknown codes decode to auto, so dedupe (keeping order) to avoid auto twice.
        var seenLanguages = Set<Language>()
        cycleLanguages = (try container.decodeIfPresent([Language].self, forKey: .cycleLanguages) ?? d.cycleLanguages)
            .filter { seenLanguages.insert($0).inserted }
        modelsDirectory = try container.decodeIfPresent(URL.self, forKey: .modelsDirectory) ?? d.modelsDirectory
        modelPath = try container.decodeIfPresent(URL.self, forKey: .modelPath) ?? d.modelPath
        vadModelPath = try container.decodeIfPresent(URL.self, forKey: .vadModelPath) ?? d.vadModelPath
        inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? d.inputDeviceUID
        autoPasteWhenSameApp = try container.decodeIfPresent(Bool.self, forKey: .autoPasteWhenSameApp) ?? d.autoPasteWhenSameApp
        normalizeAudio = try container.decodeIfPresent(Bool.self, forKey: .normalizeAudio) ?? d.normalizeAudio
        noiseReduction = try container.decodeIfPresent(Int.self, forKey: .noiseReduction) ?? d.noiseReduction
        soundFeedback = try container.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? d.soundFeedback
        soundVolume = try container.decodeIfPresent(Float.self, forKey: .soundVolume) ?? d.soundVolume
        pauseMusicWhileRecording = try container.decodeIfPresent(Bool.self, forKey: .pauseMusicWhileRecording) ?? d.pauseMusicWhileRecording
        recordingIndicatorEnabled = try container.decodeIfPresent(Bool.self, forKey: .recordingIndicatorEnabled) ?? d.recordingIndicatorEnabled
        prependAudioTags = try container.decodeIfPresent(Bool.self, forKey: .prependAudioTags) ?? d.prependAudioTags
        autoSubmitInTerminal = try container.decodeIfPresent(Bool.self, forKey: .autoSubmitInTerminal) ?? d.autoSubmitInTerminal
        autoSubmitInOtherApps = try container.decodeIfPresent(Bool.self, forKey: .autoSubmitInOtherApps) ?? d.autoSubmitInOtherApps
        translateToEnglish = try container.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? d.translateToEnglish
        lineWrapEnabled = try container.decodeIfPresent(Bool.self, forKey: .lineWrapEnabled) ?? d.lineWrapEnabled
        lineWrapWidth = try container.decodeIfPresent(Int.self, forKey: .lineWrapWidth) ?? d.lineWrapWidth
        sentencePerLine = try container.decodeIfPresent(Bool.self, forKey: .sentencePerLine) ?? d.sentencePerLine
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
        recordingTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .recordingTimeoutSeconds) ?? d.recordingTimeoutSeconds
        voiceCalibrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceCalibrationEnabled) ?? d.voiceCalibrationEnabled
        voiceCalibrationSampleText = try container.decodeIfPresent(String.self, forKey: .voiceCalibrationSampleText) ?? d.voiceCalibrationSampleText
        if let modKey = try container.decodeIfPresent(ToggleModifierKey.self, forKey: .toggleModifierKey) {
            toggleModifierKey = modKey
        } else if let legacyFn = try container.decodeIfPresent(Bool.self, forKey: .fnKeyTogglesDictation) {
            // Migrate configs persisted before the picker existed.
            toggleModifierKey = legacyFn ? .fn : .none
        } else {
            toggleModifierKey = d.toggleModifierKey
        }
        cancelKey = try container.decodeIfPresent(CancelKey.self, forKey: .cancelKey) ?? d.cancelKey
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        onboardingCompletedVersion = try container.decodeIfPresent(Int.self, forKey: .onboardingCompletedVersion) ?? d.onboardingCompletedVersion
        geminiLiveMode = (try? container.decodeIfPresent(GeminiLiveMode.self, forKey: .geminiLiveMode)) ?? d.geminiLiveMode
    }

    // Explicit CodingKeys so the decoder can reference the legacy
    // `fnKeyTogglesDictation` key (no longer a stored property) for migration.
    // Every current stored property is listed for encode/decode; `encode(to:)`
    // is auto-synthesized and will not emit the legacy key.
    private enum CodingKeys: String, CodingKey {
        case transcriptionEngine
        case selectedLanguage
        case cycleLanguages
        case modelsDirectory
        case modelPath
        case vadModelPath
        case inputDeviceUID
        case autoPasteWhenSameApp
        case normalizeAudio
        case noiseReduction
        case soundFeedback
        case soundVolume
        case pauseMusicWhileRecording
        case recordingIndicatorEnabled
        case prependAudioTags
        case autoSubmitInTerminal
        case autoSubmitInOtherApps
        case translateToEnglish
        case lineWrapEnabled
        case lineWrapWidth
        case sentencePerLine
        case launchAtLogin
        case prompt
        case recordingTimeoutSeconds
        case voiceCalibrationEnabled
        case voiceCalibrationSampleText
        case toggleModifierKey
        case cancelKey
        case showDockIcon
        case onboardingCompletedVersion
        case geminiLiveMode
        case fnKeyTogglesDictation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptionEngine, forKey: .transcriptionEngine)
        try container.encode(selectedLanguage, forKey: .selectedLanguage)
        try container.encode(cycleLanguages, forKey: .cycleLanguages)
        try container.encode(modelsDirectory, forKey: .modelsDirectory)
        try container.encode(modelPath, forKey: .modelPath)
        try container.encodeIfPresent(vadModelPath, forKey: .vadModelPath)
        try container.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try container.encode(autoPasteWhenSameApp, forKey: .autoPasteWhenSameApp)
        try container.encode(normalizeAudio, forKey: .normalizeAudio)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(soundFeedback, forKey: .soundFeedback)
        try container.encode(soundVolume, forKey: .soundVolume)
        try container.encode(pauseMusicWhileRecording, forKey: .pauseMusicWhileRecording)
        try container.encode(recordingIndicatorEnabled, forKey: .recordingIndicatorEnabled)
        try container.encode(prependAudioTags, forKey: .prependAudioTags)
        try container.encode(autoSubmitInTerminal, forKey: .autoSubmitInTerminal)
        try container.encode(autoSubmitInOtherApps, forKey: .autoSubmitInOtherApps)
        try container.encode(translateToEnglish, forKey: .translateToEnglish)
        try container.encode(lineWrapEnabled, forKey: .lineWrapEnabled)
        try container.encode(lineWrapWidth, forKey: .lineWrapWidth)
        try container.encode(sentencePerLine, forKey: .sentencePerLine)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(recordingTimeoutSeconds, forKey: .recordingTimeoutSeconds)
        try container.encode(voiceCalibrationEnabled, forKey: .voiceCalibrationEnabled)
        try container.encode(voiceCalibrationSampleText, forKey: .voiceCalibrationSampleText)
        try container.encode(toggleModifierKey, forKey: .toggleModifierKey)
        try container.encode(cancelKey, forKey: .cancelKey)
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(onboardingCompletedVersion, forKey: .onboardingCompletedVersion)
        try container.encode(geminiLiveMode, forKey: .geminiLiveMode)
    }

    public static var defaults: Config { Config() }

    /// Default cycle: auto plus the system language when whisper supports it.
    public static func defaultCycleLanguages(systemLanguage: Language? = Language.systemLanguage()) -> [Language] {
        guard let systemLanguage, systemLanguage != .auto else { return [.auto] }
        return [.auto, systemLanguage]
    }

    /// Display name of the selected model, derived from its filename (strips the
    /// `ggml-`/`whisper_` prefixes and `.bin` extension). Used for history labels
    /// and the whisper-server `model=` param. Parakeet and both Gemini engines
    /// each have a single fixed model.
    public var selectedModelName: String {
        switch transcriptionEngine {
        case .parakeet: return "parakeet-tdt-0.6b-v3"
        case .gemini: return GeminiBackend.modelID
        case .geminiLive: return GeminiLiveSession.modelID
        case .whisper: break
        }
        var name = modelPath.deletingPathExtension().lastPathComponent
        for prefix in ["whisper_ggml-", "ggml-", "whisper_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }

    /// Whether a calibration sample WAV exists on disk. Used to gate the
    /// settings toggle and the per-recording prepend decision.
    public var voiceCalibrationSampleExists: Bool {
        FileManager.default.fileExists(atPath: Constants.voiceCalibrationSamplePath.path)
    }

    /// Whether the first-run onboarding flow should be shown. True for
    /// existing installs (no stored key decodes to `0`) until they complete or
    /// skip the current version.
    public var needsOnboarding: Bool {
        onboardingCompletedVersion < Onboarding.currentVersion
    }
}
