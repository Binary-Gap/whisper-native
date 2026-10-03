import AppKit
import ScriptingBridge

/// The player controls MusicPauser needs, so tests can swap in a fake.
public protocol MusicPlayer: Sendable {
    var isRunning: Bool { get }
    /// nil when the state can't be read (e.g. Automation permission denied).
    func playerState() -> PlayerState?
    /// Returns an error description, or nil on success.
    func pause() -> String?
    /// Returns an error description, or nil on success.
    func resume() -> String?
}

@objc private protocol MusicApplication {
    @objc optional var playerState: AEKeyword { get }
    @objc optional func pause()
    @objc optional func playpause()
}
extension SBApplication: MusicApplication {}

/// Apple Music over ScriptingBridge. Every call is a synchronous Apple Event,
/// and the first one blocks until the user answers the Automation prompt, so
/// never call it on the main thread. The host app needs the
/// `com.apple.security.automation.apple-events` entitlement (hardened runtime)
/// and an `NSAppleEventsUsageDescription` string.
public struct AppleMusicPlayer: MusicPlayer {
    public static let bundleIdentifier = "com.apple.Music"

    public init() {}

    // Any ScriptingBridge message to a quit app launches it, so callers check this first.
    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    public func playerState() -> PlayerState? {
        guard let music = connect(), let code = music.playerState else { return nil }
        return PlayerState(code: code)
    }

    public func pause() -> String? {
        send { $0.pause?() }
    }

    // `playpause` from paused resumes the current track where it stopped.
    public func resume() -> String? {
        send { $0.playpause?() }
    }

    private func connect() -> MusicApplication? {
        SBApplication(bundleIdentifier: Self.bundleIdentifier)
    }

    private func send(_ command: (MusicApplication) -> Void) -> String? {
        guard let music = connect() else { return "cannot connect to Music" }
        command(music)
        return (music as? SBApplication)?.lastError().map { "\($0)" }
    }
}
