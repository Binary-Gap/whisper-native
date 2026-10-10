import AVFoundation
import XCTest
@testable import WhisperNativeCore

/// Runs the real Silero model (downloaded on first use, ~1 MB) over synthetic
/// clips: spoken text from `say`, noise and silence.
final class SpeechPresenceTests: XCTestCase {
    private static let sampleRate = 16_000
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSpeechIsSpeech() async throws {
        let speech = try spokenSamples("Let's refactor the API client and run the tests.")
        let probability = try await Self.probability(Self.noise(seconds: 1, rms: 0.002) + speech)
        XCTAssertGreaterThanOrEqual(probability, SpeechPresence.speechProbability)
    }

    func testSingleShortWordIsSpeech() async throws {
        let probability = try await Self.probability(Self.noise(seconds: 1, rms: 0.002) + spokenSamples("Yes."))
        XCTAssertGreaterThanOrEqual(probability, SpeechPresence.speechProbability)
    }

    func testVeryQuietSpeechIsSpeech() async throws {
        // A mic ~40 dB quieter than normal still has to pass.
        let speech = Self.scaled(try spokenSamples("Let's refactor the API client and run the tests."), toRMS: 0.0005)
        let probability = try await Self.probability(Self.noise(seconds: 1, rms: 0.00002) + speech)
        XCTAssertGreaterThanOrEqual(probability, SpeechPresence.speechProbability)
    }

    func testRoomNoiseIsSilence() async throws {
        for rms: Float in [0.0005, 0.003, 0.02] {
            let probability = try await Self.probability(Self.noise(seconds: 4, rms: rms))
            XCTAssertLessThan(probability, SpeechPresence.speechProbability, "noise rms \(rms)")
        }
    }

    func testDigitalSilenceIsSilence() async throws {
        let probability = try await Self.probability([Float](repeating: 0, count: Self.sampleRate * 2))
        XCTAssertLessThan(probability, SpeechPresence.speechProbability)
    }

    func testBoostCapsGainAndNeverAttenuates() {
        let quiet: [Float] = [0.0001, -0.0001]
        XCTAssertEqual(SpeechPresence.boosted(quiet), quiet.map { $0 * SpeechPresence.maximumGain })
        let loud: [Float] = [0.5, -0.5]
        XCTAssertEqual(SpeechPresence.boosted(loud), loud)
        let zeros = [Float](repeating: 0, count: 10)
        XCTAssertEqual(SpeechPresence.boosted(zeros), zeros)
    }

    func testUnreadableFileIsUnknown() async {
        let presence = await SpeechPresence.check(audioFile: tempDir.appendingPathComponent("missing.wav"))
        XCTAssertEqual(presence, .unknown)
    }

    // MARK: - Helpers

    private static func probability(_ samples: [Float]) async throws -> Float {
        let vad = try await SharedVadModel.shared.manager()
        return try await SpeechPresence.maximumSpeechProbability(in: samples, vad: vad)
    }

    private func spokenSamples(_ text: String) throws -> [Float] {
        let url = tempDir.appendingPathComponent("speech.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func noise(seconds: Double, rms: Float) -> [Float] {
        // Uniform noise in [-a, a] has RMS a / sqrt(3).
        let amplitude = rms * Float(3).squareRoot()
        return (0..<Int(seconds * Double(sampleRate))).map { _ in Float.random(in: -amplitude...amplitude) }
    }

    private static func scaled(_ samples: [Float], toRMS target: Float) -> [Float] {
        let current = SpeechOnsetGate.rms(samples)
        guard current > 0 else { return samples }
        return samples.map { $0 * target / current }
    }
}
