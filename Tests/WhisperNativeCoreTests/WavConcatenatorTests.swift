import XCTest
@testable import WhisperNativeCore

final class WavConcatenatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWav(samples: [Int16]) -> Data {
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }

        let dataSize = UInt32(pcm.count)
        let riffSize = UInt32(36) + dataSize

        var header = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(numChannels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        appendLE(dataSize)

        return header + pcm
    }

    private func writeWav(samples: [Int16], name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try makeWav(samples: samples).write(to: url)
        return url
    }

    func testConcatenateCombinesPCMFramesInOrder() throws {
        let prefixSamples: [Int16] = [1, 2, 3]
        let mainSamples: [Int16] = [10, 20, 30, 40]
        let prefixURL = try writeWav(samples: prefixSamples, name: "prefix.wav")
        let mainURL = try writeWav(samples: mainSamples, name: "main.wav")

        let combined = try WavConcatenator.concatenate(prefix: prefixURL, main: mainURL)

        // Header is 44 bytes, then PCM frames.
        XCTAssertEqual(combined.count, 44 + (prefixSamples.count + mainSamples.count) * 2)

        let dataSizeBytes = combined.subdata(in: 40..<44)
        let dataSize = dataSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(dataSize), (prefixSamples.count + mainSamples.count) * 2)

        // Verify sample order: prefix frames first, then main frames.
        let pcm = combined.subdata(in: 44..<combined.count)
        let combinedSamples: [Int16] = pcm.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Int16.self)
            return buffer.map { Int16(littleEndian: $0) }
        }
        XCTAssertEqual(combinedSamples, prefixSamples + mainSamples)
    }

    func testConcatenateRIFFHeaderSizeMatchesCombinedData() throws {
        let prefixURL = try writeWav(samples: Array(repeating: 7, count: 100), name: "prefix.wav")
        let mainURL = try writeWav(samples: Array(repeating: 9, count: 50), name: "main.wav")

        let combined = try WavConcatenator.concatenate(prefix: prefixURL, main: mainURL)

        let riffSizeBytes = combined.subdata(in: 4..<8)
        let riffSize = riffSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), combined.count - 8)
    }

    func testDurationComputedFromDataChunkSize() throws {
        // 16000 samples at 16kHz mono 16-bit = exactly 1 second.
        let url = try writeWav(samples: Array(repeating: 0, count: 16000), name: "one_second.wav")
        let duration = try WavConcatenator.duration(ofWavAt: url)
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testPcmDataThrowsOnTruncatedHeader() {
        let url = tempDir.appendingPathComponent("bad.wav")
        try? Data([0x52, 0x49]).write(to: url) // "RI" — too short to be a valid header
        XCTAssertThrowsError(try WavConcatenator.pcmData(from: url))
    }

    func testPcmDataThrowsOnUnsupportedFormat() throws {
        // Build a WAV with 44.1kHz instead of the expected 16kHz.
        var header = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(44100)) // wrong sample rate
        appendLE(UInt32(88200))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        header.append(contentsOf: "data".utf8)
        appendLE(UInt32(0))

        let url = tempDir.appendingPathComponent("wrong_format.wav")
        try header.write(to: url)

        XCTAssertThrowsError(try WavConcatenator.pcmData(from: url)) { error in
            guard case WavConcatenator.ConcatenationError.unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }
}
