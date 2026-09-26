import Foundation

// Writes raw 16-bit signed PCM samples into a RIFF WAV file at the given URL.
// Call append() repeatedly, then finalize() to seal the RIFF/data chunk sizes.
public final class WavWriter: @unchecked Sendable {
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private var dataByteCount: Int = 0

    // 44-byte RIFF WAV header constants for 16kHz mono 16-bit PCM.
    private static let sampleRate: UInt32 = 16000
    private static let numChannels: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16
    private static let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
    private static let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
    private static let headerSize = 44

    public init(url: URL) {
        self.fileURL = url
    }

    public func open() throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: fileURL)
        // Write placeholder header; sizes filled in at finalize().
        let placeholder = Data(count: Self.headerSize)
        fileHandle?.write(placeholder)
        dataByteCount = 0
    }

    public func append(_ samples: [Int16]) {
        guard let fh = fileHandle, !samples.isEmpty else { return }
        var rawData = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            rawData.append(contentsOf: withUnsafeBytes(of: &le) { Array($0) })
        }
        fh.write(rawData)
        dataByteCount += rawData.count
    }

    public func appendData(_ data: Data) {
        guard let fh = fileHandle, !data.isEmpty else { return }
        fh.write(data)
        dataByteCount += data.count
    }

    public func finalize() throws {
        guard let fh = fileHandle else { return }
        let riffSize = UInt32(Self.headerSize - 8 + dataByteCount)
        let dataSize = UInt32(dataByteCount)

        var header = Data(capacity: Self.headerSize)
        // RIFF chunk
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndianBytes: riffSize)
        header.append(contentsOf: "WAVE".utf8)
        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndianBytes: UInt32(16))          // subchunk1 size
        header.append(littleEndianBytes: UInt16(1))            // PCM
        header.append(littleEndianBytes: Self.numChannels)
        header.append(littleEndianBytes: Self.sampleRate)
        header.append(littleEndianBytes: Self.byteRate)
        header.append(littleEndianBytes: Self.blockAlign)
        header.append(littleEndianBytes: Self.bitsPerSample)
        // data subchunk
        header.append(contentsOf: "data".utf8)
        header.append(littleEndianBytes: dataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try fh.close()
        fileHandle = nil
    }

    public var currentByteCount: Int { dataByteCount }

    /// Samples written so far to a WAV that is still being recorded, as floats in
    /// -1...1. FileHandle writes go straight to disk, so the file holds every
    /// appended sample even though its header sizes are still placeholders.
    public static func readGrowingSamples(from url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count > headerSize else { return [] }
        let sampleCount = (data.count - headerSize) / 2
        return data.withUnsafeBytes { raw in
            (0..<sampleCount).map { index in
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: headerSize + index * 2, as: Int16.self))
                return Float(sample) / 32768
            }
        }
    }

    deinit {
        try? fileHandle?.close()
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndianBytes value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
