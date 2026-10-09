import Foundation

/// Paid-tier list prices of the Gemini transcription models and a per-dictation
/// cost estimate. The Live model never reports usage and the batch usage block
/// is ambiguous about what gets billed, so the estimate comes from the audio
/// length (docs: 25 audio tokens per second) and the transcript length
/// (~4 characters per output token).
public enum GeminiPricing {
    public struct Rates: Equatable, Sendable {
        public var inputDollarsPerMillionTokens: Double
        /// Covers response and thinking tokens alike.
        public var outputDollarsPerMillionTokens: Double
    }

    public static let batch = Rates(inputDollarsPerMillionTokens: 2.00, outputDollarsPerMillionTokens: 12.00)
    public static let live = Rates(inputDollarsPerMillionTokens: 3.50, outputDollarsPerMillionTokens: 21.00)

    static let audioTokensPerSecond = 25.0
    static let charactersPerOutputToken = 4.0

    /// Rates for a model ID, nil for every non-Gemini (local, free) model.
    public static func rates(forModel modelName: String) -> Rates? {
        switch modelName {
        case GeminiBackend.modelID: return batch
        case GeminiLiveSession.modelID: return live
        default: return nil
        }
    }

    /// Estimated USD for one transcription, nil for non-Gemini models or when
    /// the audio length is unknown.
    public static func estimatedDollars(modelName: String, audioSeconds: Double?, text: String) -> Double? {
        guard let rates = rates(forModel: modelName), let audioSeconds else { return nil }
        let inputTokens = audioSeconds * audioTokensPerSecond
        let outputTokens = (Double(text.count) / charactersPerOutputToken).rounded(.up)
        return (inputTokens * rates.inputDollarsPerMillionTokens
            + outputTokens * rates.outputDollarsPerMillionTokens) / 1_000_000
    }
}
