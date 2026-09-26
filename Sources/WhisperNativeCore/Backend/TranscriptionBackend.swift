import Foundation

public protocol TranscriptionBackend: Sendable {
    func transcribe(audioFile: URL, config: Config) async throws -> TranscriptionResult
    /// Like `transcribe`, but also returns per-segment timestamps (verbose_json).
    /// Used by the voice-calibration path to cut the prepended sample by acoustic
    /// position instead of fuzzy text matching.
    func transcribeWithSegments(audioFile: URL, config: Config) async throws -> (result: TranscriptionResult, segments: [TranscriptionSegment])
    func isAvailable() async -> Bool
}
