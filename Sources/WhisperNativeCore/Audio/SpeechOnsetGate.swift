import Foundation

/// Decides when continuous mic audio turns into real speech, one VAD chunk at a
/// time. A chunk qualifies when the VAD calls it speech AND it is louder than
/// the ambient noise floor by `levelMargin`; `requiredSpeechChunks` qualifying
/// chunks in a row fire the gate. The noise floor tracks the RMS of chunks the
/// VAD calls non-speech, so a fan or a quiet room raises or lowers the bar on
/// its own. Speech from across the room (TV, a call on speakers) has to beat
/// that bar too, which a voice close to the mic does easily.
public struct SpeechOnsetGate: Sendable {
    public struct Settings: Sendable {
        /// Silero probability at or above which a chunk counts as speech.
        public var speechProbability: Float = 0.85
        /// Probability below which a chunk updates the noise floor.
        public var noiseProbability: Float = 0.3
        /// Consecutive qualifying chunks needed to fire (2 x 256 ms ~ half a second).
        public var requiredSpeechChunks = 2
        /// Speech RMS must be at least this many times the noise floor (~+10 dB).
        public var levelMargin: Float = 3
        /// Absolute RMS floor, so a near-silent room doesn't make whispers and
        /// breathing count as loud enough.
        public var minimumSpeechLevel: Float = 0.01
        /// Weight of each new non-speech chunk in the noise floor average.
        public var noiseSmoothing: Float = 0.1

        public init() {}
    }

    public let settings: Settings
    public private(set) var noiseFloor: Float?
    private var speechRun = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// RMS a chunk must reach to count as speech right now.
    public var requiredLevel: Float {
        max(settings.minimumSpeechLevel, (noiseFloor ?? 0) * settings.levelMargin)
    }

    /// Feeds one chunk's VAD probability and RMS; true once the gate fires.
    public mutating func feed(probability: Float, rms: Float) -> Bool {
        if probability < settings.noiseProbability {
            noiseFloor = noiseFloor.map { $0 + (rms - $0) * settings.noiseSmoothing } ?? rms
        }
        if probability >= settings.speechProbability && rms >= requiredLevel {
            speechRun += 1
        } else {
            speechRun = 0
        }
        return speechRun >= settings.requiredSpeechChunks
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
