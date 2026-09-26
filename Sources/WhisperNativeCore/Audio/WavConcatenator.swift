import Foundation

// Concatenates two 16kHz mono 16-bit PCM WAV files (the format guaranteed by
// AudioRecorder/WavWriter) by appending raw PCM frame bytes and rewriting a
// single RIFF/WAV header sized for the combined data. Pure logic, no I/O side
// effects beyond reading the two input files — testable without a mic/server.
public enum WavConcatenator {

    public enum ConcatenationError: Error, Equatable {
        case invalidHeader(URL)
        case unsupportedFormat(URL)
    }

    private static let sampleRate: UInt32 = 16000
    private static let numChannels: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16
    private static let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
    private static let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
    private static let headerSize = 44

    /// Reads `prefix` and `main` WAV files and returns a single combined WAV
    /// (prefix's PCM frames followed by main's), with a freshly-written header.
    public static func concatenate(prefix prefixURL: URL, main mainURL: URL) throws -> Data {
        let prefixPCM = try pcmData(from: prefixURL)
        let mainPCM = try pcmData(from: mainURL)
        return wavData(pcm: prefixPCM + mainPCM)
    }

    /// Duration in seconds of a 16kHz mono 16-bit PCM WAV file, derived from its
    /// data chunk byte count (no decoding needed).
    public static func duration(ofWavAt url: URL) throws -> TimeInterval {
        let pcm = try pcmData(from: url)
        return TimeInterval(pcm.count) / TimeInterval(byteRate)
    }

    /// Appends `seconds` of silence (zeroed PCM frames) to a WAV file in place,
    /// rewriting its header for the new size. Used to pad out clipped tails
    /// (e.g. VAD cutting off the last word of a calibration sample).
    public static func appendSilence(toWavAt url: URL, seconds: TimeInterval) throws {
        let pcm = try pcmData(from: url)
        let silenceByteCount = Int(seconds * TimeInterval(byteRate))
        let silence = Data(count: silenceByteCount)
        let combined = wavData(pcm: pcm + silence)
        try combined.write(to: url)
    }

    /// Extracts the raw PCM payload (the `data` subchunk) from a WAV file,
    /// validating it matches the 16kHz/mono/16-bit format produced by WavWriter.
    public static func pcmData(from url: URL) throws -> Data {
        let fileData = try Data(contentsOf: url)
        return try pcmData(fromWavBytes: fileData, sourceURL: url)
    }

    /// Same as `pcmData(from:)` but operating on already-loaded bytes (used by
    /// unit tests to avoid touching disk).
    static func pcmData(fromWavBytes data: Data, sourceURL: URL) throws -> Data {
        guard data.count >= 44 else { throw ConcatenationError.invalidHeader(sourceURL) }

        let bytes = [UInt8](data)
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw ConcatenationError.invalidHeader(sourceURL)
        }

        // Walk subchunks looking for "fmt " and "data" (don't assume the fixed
        // 44-byte layout WavWriter happens to produce — be a tolerant reader).
        var offset = 12
        var fmtFound = false
        var dataRange: Range<Int>?

        while offset + 8 <= bytes.count {
            let chunkID = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(readUInt32LE(bytes, at: offset + 4))
            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + chunkSize
            guard chunkDataEnd <= bytes.count else { break }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else { throw ConcatenationError.unsupportedFormat(sourceURL) }
                let formatTag = readUInt16LE(bytes, at: chunkDataStart)
                let channels = readUInt16LE(bytes, at: chunkDataStart + 2)
                let rate = readUInt32LE(bytes, at: chunkDataStart + 4)
                let bits = readUInt16LE(bytes, at: chunkDataStart + 14)
                guard formatTag == 1, channels == numChannels, rate == sampleRate, bits == bitsPerSample else {
                    throw ConcatenationError.unsupportedFormat(sourceURL)
                }
                fmtFound = true
            } else if chunkID == "data" {
                dataRange = chunkDataStart..<chunkDataEnd
            }

            // Subchunks are word-aligned; skip the pad byte if chunkSize is odd.
            offset = chunkDataEnd + (chunkSize % 2)
        }

        guard fmtFound, let range = dataRange else {
            throw ConcatenationError.invalidHeader(sourceURL)
        }
        return data.subdata(in: range)
    }

    private static func wavData(pcm: Data) -> Data {
        let dataSize = UInt32(pcm.count)
        let riffSize = UInt32(headerSize - 8) + dataSize

        var header = Data(capacity: headerSize)
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndianBytes: riffSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndianBytes: UInt32(16))
        header.append(littleEndianBytes: UInt16(1)) // PCM
        header.append(littleEndianBytes: numChannels)
        header.append(littleEndianBytes: sampleRate)
        header.append(littleEndianBytes: byteRate)
        header.append(littleEndianBytes: blockAlign)
        header.append(littleEndianBytes: bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.append(littleEndianBytes: dataSize)

        return header + pcm
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndianBytes value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
