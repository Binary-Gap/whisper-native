import FluidAudio
import Foundation

/// Watches live mic audio for the moment the user starts talking, for the
/// start-on-voice mode. Runs FluidAudio's streaming Silero VAD over 256 ms
/// chunks and hands each chunk's speech probability and loudness to a
/// `SpeechOnsetGate`. Fires `onSpeechStart` once, then stops; arm a new
/// detector for the next dictation.
public final class VoiceStartDetector: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let task: Task<Void, Never>

    /// - Parameter onSpeechStart: called once, off the main thread.
    public init(gateSettings: SpeechOnsetGate.Settings = .init(), onSpeechStart: @escaping @Sendable () -> Void) {
        // ~2 s of 10 ms IO buffers, enough to ride out the model load without
        // growing unbounded; older audio is useless for spotting a fresh start.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.continuation = continuation
        task = Task.detached(priority: .userInitiated) {
            await Self.run(stream: stream, gateSettings: gateSettings, onSpeechStart: onSpeechStart)
        }
    }

    /// Queues 16 kHz mono 16-bit PCM; safe from CoreAudio's IO thread (never blocks).
    public func append(_ pcm: Data) {
        continuation.yield(pcm)
    }

    public func stop() {
        continuation.finish()
        task.cancel()
    }

    private static func run(
        stream: AsyncStream<Data>,
        gateSettings: SpeechOnsetGate.Settings,
        onSpeechStart: @Sendable () -> Void
    ) async {
        let vad: VadManager
        do {
            vad = try await SharedVadModel.shared.manager()
        } catch {
            AppLogger.shared.log(.error, "Start on voice: VAD model load failed: \(error)")
            return
        }
        var scanner = await SpeechOnsetScanner(vad: vad, gateSettings: gateSettings)
        var pending: [Float] = []
        for await pcm in stream {
            pending.append(contentsOf: floatSamples(fromPCM16: pcm))
            while pending.count >= VadManager.chunkSize {
                guard !Task.isCancelled else { return }
                let chunk = Array(pending.prefix(VadManager.chunkSize))
                pending.removeFirst(VadManager.chunkSize)
                let fired: Bool
                do {
                    fired = try await scanner.scan(chunk)
                } catch {
                    AppLogger.shared.log(.error, "Start on voice: VAD failed: \(error)")
                    return
                }
                if fired {
                    guard !Task.isCancelled else { return }
                    AppLogger.shared.log(.info, "Start on voice: speech detected (noise floor \(String(format: "%.4f", scanner.gate.noiseFloor ?? 0)))")
                    onSpeechStart()
                    return
                }
            }
        }
    }

    static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let sampleCount = data.count / 2
        return data.withUnsafeBytes { raw in
            (0..<sampleCount).map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
    }
}

/// Runs Silero over consecutive 256 ms chunks and feeds the gate. Split from
/// the detector's stream plumbing so tests can scan a whole clip directly.
struct SpeechOnsetScanner {
    let vad: VadManager
    private(set) var gate: SpeechOnsetGate
    private var streamState: VadStreamState

    init(vad: VadManager, gateSettings: SpeechOnsetGate.Settings) async {
        self.vad = vad
        gate = SpeechOnsetGate(settings: gateSettings)
        streamState = await vad.makeStreamState()
    }

    /// Scans one `VadManager.chunkSize` chunk; true once speech has started.
    mutating func scan(_ chunk: [Float]) async throws -> Bool {
        let result = try await vad.processStreamingChunk(chunk, state: streamState)
        streamState = result.state
        let rms = SpeechOnsetGate.rms(chunk)
        // Per-chunk trace for tuning the gate; Release would log it all day.
        #if DEBUG
        if result.probability >= gate.settings.noiseProbability {
            AppLogger.shared.log(
                .debug,
                "Start on voice: p=\(String(format: "%.2f", result.probability)) "
                    + "rms=\(String(format: "%.4f", rms)) need=\(String(format: "%.4f", gate.requiredLevel))"
            )
        }
        #endif
        return gate.feed(probability: result.probability, rms: rms)
    }
}

/// One Silero model for every detector, loaded (and downloaded, ~2 MB, on
/// first use) once per app run.
actor SharedVadModel {
    static let shared = SharedVadModel()

    private var loadTask: Task<VadManager, Error>?

    func manager() async throws -> VadManager {
        if let loadTask { return try await loadTask.value }
        let task = Task { try await VadManager() }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }
}
