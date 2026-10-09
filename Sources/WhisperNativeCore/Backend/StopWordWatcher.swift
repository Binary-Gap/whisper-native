import Foundation

/// Watches the live transcript of a recording and calls `onStop` once it ends
/// with one of the matcher's stop words and stays that way, so "over" followed
/// by more words ("over the weekend") never ends the dictation.
@MainActor
public final class StopWordWatcher {
    public enum Confirmation: Sendable {
        /// Two updates in a row end with the stop word. Fits Parakeet, whose
        /// previews re-transcribe the growing recording on a fixed interval:
        /// the second one covers the pause after the word.
        case consecutiveUpdates
        /// The transcript ends with the stop word and no new text arrives for
        /// this long. Fits Gemini Live, which only sends text while you talk.
        case quietPeriod(Duration)
    }

    private let matcher: StopWordMatcher
    private let confirmation: Confirmation
    private let onStop: @MainActor () -> Void
    private var lastText: String?
    private var lastEndedWithStopWord = false
    private var pendingStop: Task<Void, Never>?
    private var fired = false

    public init(matcher: StopWordMatcher, confirmation: Confirmation, onStop: @escaping @MainActor () -> Void) {
        self.matcher = matcher
        self.confirmation = confirmation
        self.onStop = onStop
    }

    public func update(text: String) {
        guard !fired else { return }
        let endsWithStopWord = matcher.endsWithStopWord(text)
        defer {
            lastText = text
            lastEndedWithStopWord = endsWithStopWord
        }
        guard endsWithStopWord else {
            cancel()
            return
        }
        switch confirmation {
        case .consecutiveUpdates:
            if lastEndedWithStopWord { fire() }
        case .quietPeriod(let quietPeriod):
            guard text != lastText else { return }
            pendingStop?.cancel()
            pendingStop = Task { [weak self] in
                try? await Task.sleep(for: quietPeriod)
                guard !Task.isCancelled else { return }
                self?.fire()
            }
        }
    }

    public func cancel() {
        pendingStop?.cancel()
        pendingStop = nil
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        cancel()
        onStop()
    }
}
