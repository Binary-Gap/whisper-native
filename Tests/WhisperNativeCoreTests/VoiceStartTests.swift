import AVFoundation
import XCTest
@testable import WhisperNativeCore

final class SpeechOnsetGateTests: XCTestCase {

    func testFiresAfterRequiredRunOfLoudSpeech() {
        var gate = SpeechOnsetGate()
        XCTAssertFalse(gate.feed(probability: 0.1, rms: 0.005))
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.1))
        XCTAssertTrue(gate.feed(probability: 0.95, rms: 0.1))
    }

    func testSingleSpeechChunkDoesNotFire() {
        var gate = SpeechOnsetGate()
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.1))
        XCTAssertFalse(gate.feed(probability: 0.2, rms: 0.005))
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.1))
    }

    func testSpeechBarelyAboveNoiseFloorDoesNotFire() {
        var gate = SpeechOnsetGate()
        for _ in 0..<10 { _ = gate.feed(probability: 0.05, rms: 0.02) }
        XCTAssertEqual(gate.noiseFloor ?? 0, 0.02, accuracy: 0.0001)
        // Speech-like but only 2x the room: a voice across the room, not at the mic.
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.04))
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.04))
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.04))
    }

    func testQuietSpeechBelowAbsoluteMinimumDoesNotFire() {
        var gate = SpeechOnsetGate()
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.005))
        XCTAssertFalse(gate.feed(probability: 0.95, rms: 0.005))
    }

    func testLoudNonSpeechDoesNotFire() {
        var gate = SpeechOnsetGate()
        for _ in 0..<5 {
            XCTAssertFalse(gate.feed(probability: 0.4, rms: 0.3))
        }
    }
}

/// Runs the real Silero model (downloaded into FluidAudio's cache on first use)
/// over synthetic room audio, with speech from the system `say` voice.
final class SpeechOnsetScannerTests: XCTestCase {

    private static let sampleRate = 16_000
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCloseSpeechFiresSoonAfterItStarts() async throws {
        let room = Self.noise(seconds: 2, rms: 0.003)
        let speech = Self.scaled(try spokenSamples("Let's refactor the API client and run the tests."), toRMS: 0.08)
        let fireTime = try await Self.firstFireTime(in: room + speech + room)
        let fire = try XCTUnwrap(fireTime, "speech never fired the gate")
        XCTAssertGreaterThan(fire, 2.0, "fired before the speech")
        // Comfortably inside the pre-roll, so the first word still lands in the recording.
        XCTAssertLessThan(fire - 2.0, Constants.voiceStartPreRoll - 0.3)
    }

    func testDistantSpeechDoesNotFire() async throws {
        let room = Self.noise(seconds: 3, rms: 0.01)
        // Same room noise under the speech, which sits at about the room's level.
        let speech = Self.scaled(try spokenSamples("Let's refactor the API client and run the tests."), toRMS: 0.01)
        let speechInRoom = zip(speech, Self.noise(seconds: Double(speech.count) / Double(Self.sampleRate), rms: 0.01))
            .map { $0 + $1 }
        let fireTime = try await Self.firstFireTime(in: room + speechInRoom + Self.noise(seconds: 1, rms: 0.01))
        XCTAssertNil(fireTime)
    }

    func testNoiseAndClicksDoNotFire() async throws {
        var audio = Self.noise(seconds: 3, rms: 0.003)
        // Keyboard-like clicks: 10 ms bursts every 150 ms.
        for start in stride(from: 0, to: audio.count - 160, by: Self.sampleRate * 15 / 100) {
            for index in start..<(start + 160) { audio[index] += Float.random(in: -0.6...0.6) }
        }
        audio += Self.noise(seconds: 3, rms: 0.1)
        let fireTime = try await Self.firstFireTime(in: audio)
        XCTAssertNil(fireTime)
    }

    // MARK: - Helpers

    /// Seconds into `samples` at which the scanner fires, or nil.
    private static func firstFireTime(in samples: [Float]) async throws -> Double? {
        let vad = try await SharedVadModel.shared.manager()
        var scanner = await SpeechOnsetScanner(vad: vad, gateSettings: .init())
        let chunkSize = 4096
        var offset = 0
        while offset + chunkSize <= samples.count {
            if try await scanner.scan(Array(samples[offset..<(offset + chunkSize)])) {
                return Double(offset + chunkSize) / Double(sampleRate)
            }
            offset += chunkSize
        }
        return nil
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
        XCTAssertEqual(file.processingFormat.sampleRate, Double(Self.sampleRate))
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
