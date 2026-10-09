import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Toggle dictation on/off. Default: Right Option (Carbon keyCode 61, no modifiers).
    public static let toggleDictation = Self(
        "toggleDictation",
        default: .init(carbonKeyCode: 61, carbonModifiers: 0)
    )
    // Cancel in-progress transcription.
    public static let cancelTranscription = Self(
        "cancelTranscription",
        default: .init(.escape, modifiers: [])
    )
    // Cycle the transcription language: pt -> en -> auto. Default: Option+Tab.
    public static let cycleLanguage = Self(
        "cycleLanguage",
        default: .init(.tab, modifiers: [.option])
    )
    // Turn start on voice on/off. Default: Control+Option+V.
    public static let toggleStartOnVoice = Self(
        "toggleStartOnVoice",
        default: .init(.v, modifiers: [.control, .option])
    )
    // Paste the most recent transcript at cursor.
    public static let pasteLastTranscript = Self(
        "pasteLastTranscript",
        default: .init(.v, modifiers: [.shift, .command])
    )
}
