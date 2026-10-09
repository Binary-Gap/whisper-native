import Foundation
import Testing
@testable import MusicPause

private final class FakePlayer: MusicPlayer, @unchecked Sendable {
    var isRunning = true
    var state: PlayerState? = .playing
    var calls: [String] = []

    func playerState() -> PlayerState? { state }

    func pause() -> String? {
        calls.append("pause")
        state = .paused
        return nil
    }

    func resume() -> String? {
        calls.append("resume")
        state = .playing
        return nil
    }
}

private func makePauser(_ player: FakePlayer) -> (MusicPauser, DispatchQueue) {
    let queue = DispatchQueue(label: "test")
    return (MusicPauser(player: player, queue: queue), queue)
}

@Test func pausesPlayingMusicAndResumesIt() {
    let player = FakePlayer()
    let (pauser, queue) = makePauser(player)
    pauser.pause()
    pauser.resume()
    queue.sync {}
    #expect(player.calls == ["pause", "resume"])
}

@Test func leavesMusicThatWasNotPlaying() {
    let player = FakePlayer()
    player.state = .paused
    let (pauser, queue) = makePauser(player)
    pauser.pause()
    pauser.resume()
    queue.sync {}
    #expect(player.calls.isEmpty)
}

@Test func neverTouchesMusicThatIsNotRunning() {
    let player = FakePlayer()
    player.isRunning = false
    let (pauser, queue) = makePauser(player)
    pauser.pause()
    pauser.resume()
    queue.sync {}
    #expect(player.calls.isEmpty)
}

@Test func skipsResumeWhenUserChangedPlaybackMeanwhile() {
    let player = FakePlayer()
    let (pauser, queue) = makePauser(player)
    pauser.pause()
    queue.sync { player.state = .stopped }
    pauser.resume()
    queue.sync {}
    #expect(player.calls == ["pause"])
}

@Test func resumesOnlyOnceAfterRepeatedStops() {
    let player = FakePlayer()
    let (pauser, queue) = makePauser(player)
    pauser.pause()
    pauser.resume()
    pauser.resume()
    queue.sync {}
    #expect(player.calls == ["pause", "resume"])
}

@Test func decodesPlayerStateCodes() {
    #expect(PlayerState(code: 0x6B50_5350) == .playing)
    #expect(PlayerState(code: 0x6B50_5370) == .paused)
    #expect(PlayerState(code: 0) == nil)
}
