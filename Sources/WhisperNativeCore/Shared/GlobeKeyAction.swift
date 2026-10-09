import Foundation

/// What macOS does on a Globe (Fn) key press, from System Settings › Keyboard
/// "Press 🌐 key to" (`AppleFnUsageType` in `com.apple.HIToolbox`). Fn as the
/// dictation key only works cleanly with `.doNothing`; any other action fires
/// on every tap too.
public enum GlobeKeyAction: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case showEmoji
    case startDictation
    /// Key absent (never changed) or a value this build doesn't know.
    case other

    public init(preferenceValue: Int?) {
        switch preferenceValue {
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .showEmoji
        case 3: self = .startDictation
        default: self = .other
        }
    }

    /// Reads the current setting; re-synchronizes first since System Settings
    /// writes it from another process.
    public static var current: GlobeKeyAction {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int
        return GlobeKeyAction(preferenceValue: value)
    }

    /// Name as System Settings shows it, nil when unknown.
    public var displayName: String? {
        switch self {
        case .doNothing: "Do Nothing"
        case .changeInputSource: "Change Input Source"
        case .showEmoji: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        case .other: nil
        }
    }

    /// Warning shown while Fn is the dictation key and the Globe key still has
    /// an action; nil when it is set to Do Nothing.
    public var fnConflictWarning: String? {
        guard self != .doNothing else { return nil }
        let current = displayName.map { " is set to “\($0)”, so macOS" } ?? " has an action, so macOS"
        return "The Globe key\(current) also reacts to every Fn tap. Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings."
    }

    public static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}
