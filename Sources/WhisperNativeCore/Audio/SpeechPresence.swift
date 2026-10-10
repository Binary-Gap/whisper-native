import FluidAudio
import Foundation

/// Local "was anything said?" check on a finished recording, run before a
/// billed Gemini call so a silent clip is dropped instead of sent. Silero VAD
/// over the whole clip, boosted first so a quiet mic still scores as speech
/// (Silero's score drops with level). Any doubt (model missing, read or VAD
/// failure) answers `.unknown`, which callers treat as speech.
public enum SpeechPresence: Sendable, Equatable {
    case speech
    case silence
    case unknown

    /// Silero probability one 256 ms chunk must reach for the clip to count as
    /// speech. Boosted real speech scores ~1.0; boosted room noise stays well
    /// below this.
    static let speechProbability: Float = 0.85
    /// RMS the loudest chunk is boosted to before scoring (normal speech level).
    static let targetChunkLevel: Float = 0.05
    /// Gain cap (+40 dB), so a near-digital-silence clip isn't blown up into noise.
    static let maximumGain: Float = 100

    public static func check(audioFile: URL) async -> SpeechPresence {
        guard ParakeetModelKind.vad.isDownloaded() else {
            // Fetches the ~1 MB model for the next dictation; this one goes out unchecked.
            Task.detached { _ = try? await SharedVadModel.shared.manager() }
            AppLogger.shared.log(.info, "Speech check skipped: VAD model not downloaded yet")
            return .unknown
        }
        do {
            let startTime = Date()
            let samples = try AudioConverter().resampleAudioFile(audioFile)
            let vad = try await SharedVadModel.shared.manager()
            let probability = try await maximumSpeechProbability(in: samples, vad: vad)
            let verdict: SpeechPresence = probability >= speechProbability ? .speech : .silence
            AppLogger.shared.log(
                .info,
                "Speech check: \(verdict) maxProbability=\(String(format: "%.2f", probability)) "
                    + "audioSeconds=\(String(format: "%.1f", Double(samples.count) / Double(VadManager.sampleRate))) "
                    + "tookMs=\(Int(Date().timeIntervalSince(startTime) * 1000))"
            )
            return verdict
        } catch {
            AppLogger.shared.log(.warning, "Speech check failed, sending the clip: \(error)")
            return .unknown
        }
    }

    static func maximumSpeechProbability(in samples: [Float], vad: VadManager) async throws -> Float {
        try await vad.process(boosted(samples)).map(\.probability).max() ?? 0
    }

    /// Scales the clip so its loudest chunk reaches `targetChunkLevel`; never
    /// attenuates.
    static func boosted(_ samples: [Float]) -> [Float] {
        var loudest: Float = 0
        for start in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
            let end = min(start + VadManager.chunkSize, samples.count)
            loudest = max(loudest, SpeechOnsetGate.rms(Array(samples[start..<end])))
        }
        guard loudest > 0 else { return samples }
        let gain = min(maximumGain, max(1, targetChunkLevel / loudest))
        return gain == 1 ? samples : samples.map { $0 * gain }
    }
}
