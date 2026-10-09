import Foundation

public enum AppError: Error, Sendable {
    case serverNotRunning
    case serverUnhealthy(String)
    case recordingFailed(String)
    case transcriptionFailed(String)
    case transcriptionEmpty
    case textInsertionFailed(String)
    case accessibilityDenied
    case modelNotFound(URL)
    case audioFileTooSmall(Int)
    case geminiAPIKeyMissing
    case keychainFailed(OSStatus)
}

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "whisper-server is not running"
        case .serverUnhealthy(let reason):
            return "whisper-server unhealthy: \(reason)"
        case .recordingFailed(let reason):
            return "Recording failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .transcriptionEmpty:
            return "Transcription returned empty text"
        case .textInsertionFailed(let reason):
            return "Text insertion failed: \(reason)"
        case .accessibilityDenied:
            return "Accessibility permission denied — synthesised keystrokes are dropped. "
                + "Grant it in System Settings > Privacy & Security > Accessibility. "
                + "The transcript is on the clipboard; paste it manually."
        case .modelNotFound(let url):
            return "Model not found at \(url.path)"
        case .audioFileTooSmall(let bytes):
            return "Audio file too small (\(bytes) bytes)"
        case .geminiAPIKeyMissing:
            return "No Gemini API key. Add one in Settings > Gemini (or set GEMINI_API_KEY)."
        case .keychainFailed(let status):
            return "Keychain error (OSStatus \(status))"
        }
    }
}
