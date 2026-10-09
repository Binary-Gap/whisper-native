import Foundation

/// Pauses music for the length of a recording and resumes only what it paused:
/// music that wasn't playing, or that the user paused or restarted in the
/// meantime, is left alone. Calls return immediately; the Apple Events run in
/// order on a private serial queue.
public final class MusicPauser: @unchecked Sendable {
    private let player: any MusicPlayer
    private let queue: DispatchQueue
    private let report: @Sendable (String) -> Void
    // Confined to `queue`.
    private var pausedPlayback = false

    /// `report` receives one line per action taken or failure, on `queue`.
    public init(
        player: any MusicPlayer = AppleMusicPlayer(),
        queue: DispatchQueue = DispatchQueue(label: "MusicPause.MusicPauser"),
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.player = player
        self.queue = queue
        self.report = report
    }

    public func pause() {
        queue.async { [self] in
            guard !pausedPlayback, player.isRunning else { return }
            switch player.playerState() {
            case .playing:
                if let error = player.pause() {
                    report("Music pause failed: \(error)")
                } else {
                    pausedPlayback = true
                    report("Music paused")
                }
            case nil:
                report("Music state unreadable; check System Settings > Privacy & Security > Automation")
            default:
                break
            }
        }
    }

    public func resume() {
        queue.async { [self] in
            guard pausedPlayback else { return }
            pausedPlayback = false
            guard player.isRunning, player.playerState() == .paused else {
                report("Music resume skipped: no longer paused")
                return
            }
            if let error = player.resume() {
                report("Music resume failed: \(error)")
            } else {
                report("Music resumed")
            }
        }
    }
}
