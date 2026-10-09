import XCTest
@testable import WhisperNativeCore

final class StopWordMatcherTests: XCTestCase {
    private let defaults = StopWordMatcher(words: ["over", "câmbio"])

    func testMatchesOnlyAsTheLastWord() {
        XCTAssertTrue(defaults.endsWithStopWord("Ship it over"))
        XCTAssertTrue(defaults.endsWithStopWord("Ship it. Over."))
        XCTAssertTrue(defaults.endsWithStopWord("ship it, OVER!"))
        XCTAssertTrue(defaults.endsWithStopWord("Over."))
        XCTAssertTrue(defaults.endsWithStopWord("Ship it, over.\n"))
        XCTAssertTrue(defaults.endsWithStopWord("Ship it...over"))
        XCTAssertFalse(defaults.endsWithStopWord("Let's talk it over the weekend"))
        XCTAssertFalse(defaults.endsWithStopWord("A hostile takeover"))
        XCTAssertFalse(defaults.endsWithStopWord("Read the overview"))
        XCTAssertFalse(defaults.endsWithStopWord(""))
        XCTAssertFalse(defaults.endsWithStopWord(" ,. "))
    }

    func testIgnoresCaseAndAccentsBothWays() {
        XCTAssertTrue(defaults.endsWithStopWord("Pode mandar, câmbio."))
        XCTAssertTrue(defaults.endsWithStopWord("Pode mandar. Câmbio!"))
        XCTAssertTrue(defaults.endsWithStopWord("pode mandar cambio"))
        XCTAssertTrue(defaults.endsWithStopWord("Pode mandar, ca\u{0302}mbio."), "decomposed accent")
        XCTAssertFalse(defaults.endsWithStopWord("O câmbio do carro quebrou"))
        let unaccented = StopWordMatcher(words: ["CAMBIO"])
        XCTAssertTrue(unaccented.endsWithStopWord("Pode mandar, câmbio."))
        XCTAssertEqual(unaccented.removingStopWord(from: "Pode mandar, Câmbio."), "Pode mandar")
    }

    func testMultiWordPhrasesMatchWithAnySeparatorBetweenWords() {
        let matcher = StopWordMatcher(words: ["over and out"])
        XCTAssertTrue(matcher.endsWithStopWord("Roger, over and out."))
        XCTAssertTrue(matcher.endsWithStopWord("Roger. Over, and out!"))
        XCTAssertTrue(matcher.endsWithStopWord("roger over-and-out"))
        XCTAssertTrue(matcher.endsWithStopWord("Over  and\nout"))
        XCTAssertFalse(matcher.endsWithStopWord("Roger, over and outside"))
        XCTAssertFalse(matcher.endsWithStopWord("Roger, leftover and out"))
        XCTAssertFalse(matcher.endsWithStopWord("Roger, and out"))
        XCTAssertFalse(matcher.endsWithStopWord("Roger, over"))
        XCTAssertEqual(matcher.removingStopWord(from: "Roger, over and out."), "Roger")
    }

    func testLongestMatchingPhraseIsRemoved() {
        let matcher = StopWordMatcher(words: ["out", "over and out"])
        XCTAssertEqual(matcher.removingStopWord(from: "Roger, over and out."), "Roger")
        XCTAssertEqual(matcher.removingStopWord(from: "Get out"), "Get")
    }

    func testWordsAreTrimmedAndDeduplicatedIgnoringCaseAndAccents() {
        let matcher = StopWordMatcher(words: [" over ", "", "Over", "  ", "câmbio", "cambio", "...", "over  and out", "Over and out"])
        XCTAssertEqual(matcher.words, ["over", "câmbio", "over  and out"])
        XCTAssertFalse(matcher.isEmpty)
    }

    func testEmptyMatcherNeverMatches() {
        let matcher = StopWordMatcher(words: [])
        XCTAssertTrue(matcher.isEmpty)
        XCTAssertFalse(matcher.endsWithStopWord("Ship it, over."))
        XCTAssertEqual(matcher.removingStopWord(from: "Ship it, over."), "Ship it, over.")
    }

    func testRemovesTheWordAndThePunctuationTyingIt() {
        XCTAssertEqual(defaults.removingStopWord(from: "Ship it, over."), "Ship it")
        XCTAssertEqual(defaults.removingStopWord(from: "Ship it. Over."), "Ship it.")
        XCTAssertEqual(defaults.removingStopWord(from: "ship it over"), "ship it")
        XCTAssertEqual(defaults.removingStopWord(from: "Ship it; over"), "Ship it")
        XCTAssertEqual(defaults.removingStopWord(from: "Ship it: over!"), "Ship it")
        XCTAssertEqual(defaults.removingStopWord(from: "Ship it - over"), "Ship it")
        XCTAssertEqual(defaults.removingStopWord(from: "Ship it — over."), "Ship it")
        XCTAssertEqual(defaults.removingStopWord(from: "Pode mandar. Câmbio."), "Pode mandar.")
        XCTAssertEqual(defaults.removingStopWord(from: "Over."), "")
        XCTAssertEqual(defaults.removingStopWord(from: "Game over the top"), "Game over the top")
    }
}

@MainActor
final class StopWordWatcherTests: XCTestCase {
    private let matcher = StopWordMatcher(words: ["over", "câmbio"])

    func testConsecutiveUpdatesFireOnTheSecondEnding() {
        var stops = 0
        let watcher = StopWordWatcher(matcher: matcher, confirmation: .consecutiveUpdates) { stops += 1 }
        watcher.update(text: "Ship it")
        watcher.update(text: "Ship it, over")
        XCTAssertEqual(stops, 0)
        watcher.update(text: "Ship it, over.")
        XCTAssertEqual(stops, 1)
        watcher.update(text: "Ship it, over.")
        XCTAssertEqual(stops, 1, "fires once per recording")
    }

    func testMoreWordsAfterTheStopWordResetConsecutiveUpdates() {
        var stops = 0
        let watcher = StopWordWatcher(matcher: matcher, confirmation: .consecutiveUpdates) { stops += 1 }
        watcher.update(text: "Talk it over")
        watcher.update(text: "Talk it over the weekend")
        watcher.update(text: "Talk it over the weekend, over")
        XCTAssertEqual(stops, 0)
    }

    func testQuietPeriodFiresAfterSilence() async throws {
        var stops = 0
        let watcher = StopWordWatcher(matcher: matcher, confirmation: .quietPeriod(.milliseconds(100))) { stops += 1 }
        watcher.update(text: "Ship it, over")
        XCTAssertEqual(stops, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stops, 1)
    }

    func testQuietPeriodCancelledByMoreWords() async throws {
        var stops = 0
        let watcher = StopWordWatcher(matcher: matcher, confirmation: .quietPeriod(.milliseconds(150))) { stops += 1 }
        watcher.update(text: "Talk it over")
        watcher.update(text: "Talk it over the weekend")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(stops, 0)
    }

    func testQuietPeriodCancelledExplicitly() async throws {
        var stops = 0
        let watcher = StopWordWatcher(matcher: matcher, confirmation: .quietPeriod(.milliseconds(100))) { stops += 1 }
        watcher.update(text: "Ship it, over")
        watcher.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stops, 0)
    }
}
