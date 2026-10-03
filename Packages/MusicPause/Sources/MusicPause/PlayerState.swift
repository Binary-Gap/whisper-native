/// Apple Music's `playerState` property, decoded from the four-char AppleEvent code
/// (Music's scripting dictionary, `sdef /System/Applications/Music.app`, enumeration `ePlS`).
public enum PlayerState: String, Sendable {
    case stopped
    case playing
    case paused
    case fastForwarding = "fast-forwarding"
    case rewinding

    /// nil for unknown codes and for 0, which ScriptingBridge returns when the
    /// state can't be read (Automation permission denied).
    public init?(code: UInt32) {
        switch code {
        case 0x6B50_5353: self = .stopped        // 'kPSS'
        case 0x6B50_5350: self = .playing        // 'kPSP'
        case 0x6B50_5370: self = .paused         // 'kPSp'
        case 0x6B50_5346: self = .fastForwarding // 'kPSF'
        case 0x6B50_5352: self = .rewinding      // 'kPSR'
        default: return nil
        }
    }
}
