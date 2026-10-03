import Foundation

/// One Gemini Live transcription session per dictation, over a WebSocket to
/// `BidiGenerateContent` with manual activity detection. `start()` connects and
/// sends setup at recording start; `appendPCM` takes recorder audio (buffered
/// until setupComplete, then streamed as 100 ms chunks after an activityStart);
/// `finish` sends activityEnd and returns the joined final segments once the
/// server reports generationComplete; `cancel` closes the socket without
/// activityEnd. The key travels in the `x-goog-api-key` header, so the URL is
/// safe to log. All state lives on one serial queue, which keeps audio chunks
/// in recording order.
public final class GeminiLiveSession: @unchecked Sendable {
    public static let modelID = "gemini-3.5-transcribe-live"
    public static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!

    /// Timings and volume of one session, for the per-dictation log line.
    public struct Metrics: Sendable {
        /// start() -> socket open.
        public var openMilliseconds: Int?
        /// start() -> setupComplete.
        public var setupMilliseconds: Int?
        /// finish() -> generationComplete.
        public var stopToFinalMilliseconds: Int?
        public var audioSeconds: Double
        public var interimCount: Int
        public var finalSegmentCount: Int
    }

    private enum State {
        case idle
        case connecting
        case streaming
        case completed
        case failed(String)
        case cancelled
    }

    private let apiKey: String
    private let languageCodes: [String]
    private let mode: GeminiLiveMode
    private let onPreview: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "io.binarygap.whisper-native.gemini-live")

    // Queue-confined state.
    private var state: State = .idle
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var chunker = PCMChunker(chunkBytes: GeminiLiveProtocol.chunkBytes)
    private var audioBytes = 0
    private var finalSegments: [String] = []
    private var currentInterim = ""
    private var interimCount = 0
    private var endRequested = false
    private var activityEndSent = false
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var startedAt: Date?
    private var openedAt: Date?
    private var setupCompletedAt: Date?
    private var finishRequestedAt: Date?
    private var finishedAt: Date?
    private var loggedUnknownKeys: Set<String> = []

    /// `onPreview` gets the running transcript (finals so far plus the current
    /// interim) on the session queue whenever an interim or final arrives.
    public init(
        apiKey: String,
        languageCodes: [String],
        mode: GeminiLiveMode,
        onPreview: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.languageCodes = languageCodes
        self.mode = mode
        self.onPreview = onPreview
    }

    // MARK: - Public API

    /// Opens the socket and sends setup. Returns immediately.
    public func start() {
        queue.async { self.connect() }
    }

    /// Queues recorder PCM (16 kHz mono 16-bit LE). Safe from the audio thread:
    /// it only hops onto the session queue.
    public func appendPCM(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { self.bufferAndStream(data) }
    }

    /// Flushes the remaining audio, sends activityEnd and waits (at most
    /// `timeout` seconds) for the final transcript. Throws on connect errors,
    /// socket drops and timeouts, and `CancellationError` after `cancel()`.
    public func finish(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.beginFinish(continuation, timeout: timeout) }
        }
    }

    /// Closes the socket without activityEnd; a pending `finish` throws
    /// `CancellationError`.
    public func cancel() {
        queue.async {
            switch self.state {
            case .completed, .failed, .cancelled: return
            default: break
            }
            self.state = .cancelled
            self.closeSocket(code: .goingAway)
            self.resumeFinish(with: .failure(CancellationError()))
        }
    }

    public var metrics: Metrics {
        queue.sync {
            Metrics(
                openMilliseconds: Self.milliseconds(from: startedAt, to: openedAt),
                setupMilliseconds: Self.milliseconds(from: startedAt, to: setupCompletedAt),
                stopToFinalMilliseconds: Self.milliseconds(from: finishRequestedAt, to: finishedAt),
                audioSeconds: Double(audioBytes) / Double(GeminiLiveProtocol.bytesPerSecond),
                interimCount: interimCount,
                finalSegmentCount: finalSegments.count
            )
        }
    }

    // MARK: - Connection

    private func connect() {
        guard case .idle = state else { return }
        state = .connecting
        startedAt = Date()

        let delegate = SocketDelegate(
            onOpen: { [weak self] in
                guard let self else { return }
                self.queue.async { self.openedAt = Date() }
            },
            onClose: { [weak self] code, reason in
                guard let self else { return }
                self.queue.async { self.handleClose(code: code, reason: reason) }
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: Self.endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        task.resume()
        send(GeminiLiveProtocol.setupMessage(model: Self.modelID, languageCodes: languageCodes, mode: mode))
        receiveNext()
        AppLogger.shared.log(
            .info,
            "Gemini Live connecting: \(Self.endpoint.absoluteString) model=\(Self.modelID) "
                + "languageCodes=\(languageCodes) mode=\(mode.rawValue)"
        )
    }

    private func receiveNext() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async { self.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard isActive else { return }
        switch result {
        case .failure(let error):
            fail("socket receive failed: \(error.localizedDescription)")
        case .success(let message):
            let data: Data
            switch message {
            case .data(let payload): data = payload
            case .string(let text): data = Data(text.utf8)
            @unknown default: data = Data()
            }
            #if DEBUG
            logUnknownKeys(in: data)
            #endif
            for event in GeminiLiveProtocol.events(from: data) {
                handle(event)
            }
            if isActive { receiveNext() }
        }
    }

    private func handle(_ event: GeminiLiveEvent) {
        if case .usage(let reported) = event {
            logUsage(reported)
            return
        }
        guard isActive else { return }
        switch event {
        case .setupComplete:
            guard case .connecting = state else { return }
            state = .streaming
            setupCompletedAt = Date()
            send(GeminiLiveProtocol.activityStartMessage())
            streamFullChunks()
            if endRequested { sendActivityEnd() }
        case .interim(let text):
            interimCount += 1
            currentInterim = text
            onPreview(previewText)
        case .final(let text):
            finalSegments.append(text)
            currentInterim = ""
            onPreview(previewText)
        case .generationComplete, .turnComplete:
            // Only the turn closed by our activityEnd carries the whole dictation.
            guard activityEndSent else { return }
            state = .completed
            finishedAt = Date()
            let transcript = GeminiLiveProtocol.joinSegments(finalSegments)
            resumeFinish(with: .success(transcript))
            // The Live API has no end-of-session message: the client always
            // closes, which the API dashboard counts as a 409 ABORTED.
            closeSocket(code: .normalClosure)
        case .usage:
            break
        case .goAway:
            AppLogger.shared.log(.warning, "Gemini Live: server sent goAway")
        case .error(let message):
            fail("server error: \(message)")
        }
    }

    private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard isActive else { return }
        let reasonText = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        fail("socket closed by server: code=\(code.rawValue) reason=\(reasonText)")
    }

    // MARK: - Audio

    private func bufferAndStream(_ data: Data) {
        guard isActive, !endRequested else { return }
        chunker.append(data)
        audioBytes += data.count
        if case .streaming = state { streamFullChunks() }
    }

    private func streamFullChunks() {
        while let chunk = chunker.nextFullChunk() {
            send(GeminiLiveProtocol.audioMessage(pcm: chunk))
        }
    }

    private func sendActivityEnd() {
        guard !activityEndSent else { return }
        streamFullChunks()
        if let remainder = chunker.flush() {
            send(GeminiLiveProtocol.audioMessage(pcm: remainder))
        }
        send(GeminiLiveProtocol.activityEndMessage())
        activityEndSent = true
    }

    // MARK: - Finish

    private func beginFinish(_ continuation: CheckedContinuation<String, Error>, timeout: TimeInterval) {
        switch state {
        case .failed(let reason):
            continuation.resume(throwing: AppError.transcriptionFailed("Gemini Live \(reason)"))
            return
        case .cancelled:
            continuation.resume(throwing: CancellationError())
            return
        case .completed:
            continuation.resume(returning: GeminiLiveProtocol.joinSegments(finalSegments))
            return
        case .idle:
            continuation.resume(throwing: AppError.transcriptionFailed("Gemini Live session never started"))
            return
        case .connecting, .streaming:
            break
        }
        finishContinuation = continuation
        finishRequestedAt = Date()
        endRequested = true
        // Before setupComplete the flush waits for it (handle(.setupComplete)).
        if case .streaming = state { sendActivityEnd() }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.finishContinuation != nil else { return }
            let phase = self.setupCompletedAt == nil ? "setupComplete" : "final transcript"
            self.fail("timed out after \(timeout)s waiting for \(phase)")
        }
    }

    private func resumeFinish(with result: Result<String, Error>) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Usage (Debug builds only)

    #if DEBUG
    /// Token counts and estimated cost, logged if the server reports usage
    /// before the socket closes (gemini-3.5-transcribe-live has not so far).
    private func logUsage(_ usage: GeminiLiveUsage) {
        let audioSeconds = String(format: "%.1f", Double(audioBytes) / Double(GeminiLiveProtocol.bytesPerSecond))
        AppLogger.shared.log(
            .info,
            "Gemini Live usage: mode=\(mode.rawValue) audioSeconds=\(audioSeconds) "
                + "promptTokens=\(usage.promptTokens) responseTokens=\(usage.responseTokens) "
                + "thoughtsTokens=\(usage.thoughtsTokens) totalTokens=\(usage.totalTokens) "
                + "estimatedUSD=\(String(format: "%.5f", usage.estimatedDollars))"
        )
    }

    private func logUnknownKeys(in data: Data) {
        let newKeys = GeminiLiveProtocol.unknownMessageKeys(in: data).filter { !loggedUnknownKeys.contains($0) }
        guard !newKeys.isEmpty else { return }
        loggedUnknownKeys.formUnion(newKeys)
        AppLogger.shared.log(.info, "Gemini Live: unhandled server message keys \(newKeys)")
    }
    #else
    private func logUsage(_ usage: GeminiLiveUsage) {}
    #endif

    // MARK: - Helpers

    private var isActive: Bool {
        switch state {
        case .connecting, .streaming: true
        case .idle, .completed, .failed, .cancelled: false
        }
    }

    private var previewText: String {
        GeminiLiveProtocol.joinSegments(finalSegments + [currentInterim])
    }

    private func fail(_ reason: String) {
        guard isActive else { return }
        state = .failed(reason)
        AppLogger.shared.log(.warning, "Gemini Live failed: \(reason)")
        closeSocket(code: .goingAway)
        resumeFinish(with: .failure(AppError.transcriptionFailed("Gemini Live \(reason)")))
    }

    private func send(_ text: String) {
        webSocketTask?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.fail("socket send failed: \(error.localizedDescription)") }
        }
    }

    private func closeSocket(code: URLSessionWebSocketTask.CloseCode) {
        webSocketTask?.cancel(with: code, reason: nil)
        webSocketTask = nil
        // The session retains its delegate until invalidated.
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}

/// Collects recorder buffers of any size into fixed-size chunks.
struct PCMChunker {
    let chunkBytes: Int
    private var buffer = Data()

    init(chunkBytes: Int) {
        self.chunkBytes = chunkBytes
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Next complete chunk, nil when less than a chunk is buffered.
    mutating func nextFullChunk() -> Data? {
        guard buffer.count >= chunkBytes else { return nil }
        let chunk = Data(buffer.prefix(chunkBytes))
        buffer = Data(buffer.dropFirst(chunkBytes))
        return chunk
    }

    /// Whatever is left (shorter than a chunk), nil when empty.
    mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let rest = buffer
        buffer = Data()
        return rest
    }
}

/// Forwards the WebSocket open and close callbacks.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @Sendable () -> Void
    private let onClose: @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void

    init(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(closeCode, reason)
    }
}
