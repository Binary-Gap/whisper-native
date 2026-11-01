import AudioToolbox
import XCTest
@testable import WhisperNativeCore

final class FirstAudioWaitTests: XCTestCase {
    func testAudioAlreadyFlowingReturnsAtOnce() async {
        let elapsed = await FirstAudioWait.wait(timeout: .seconds(1)) { true }
        XCTAssertNotNil(elapsed)
        XCTAssertLessThan(elapsed ?? .seconds(1), .milliseconds(100))
    }

    func testNoAudioTimesOut() async {
        let clock = ContinuousClock()
        let start = clock.now
        let elapsed = await FirstAudioWait.wait(timeout: .milliseconds(150)) { false }
        XCTAssertNil(elapsed)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(150))
    }

    func testAudioArrivingWithinTheWindowCounts() async {
        let flag = Flag()
        let flipper = Task {
            try? await Task.sleep(for: .milliseconds(60))
            flag.set()
        }
        let elapsed = await FirstAudioWait.wait(timeout: .seconds(1)) { flag.isSet }
        _ = await flipper.value
        XCTAssertGreaterThanOrEqual(elapsed ?? .zero, .milliseconds(60))
        XCTAssertLessThan(elapsed ?? .seconds(1), .milliseconds(500))
    }

    func testCancelledWaitReturnsNil() async {
        let waiter = Task { await FirstAudioWait.wait(timeout: .seconds(5)) { false } }
        waiter.cancel()
        let elapsed = await waiter.value
        XCTAssertNil(elapsed)
    }

    // The fallback watches recordedBytes: listened audio (no WAV yet) must not
    // count, recorded audio must.
    func testCaptureContextCountsOnlyRecordedAudio() throws {
        var nativeFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var targetFormat = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var converter: AudioConverterRef?
        XCTAssertEqual(AudioConverterNew(&nativeFormat, &targetFormat, &converter), noErr)
        let conv = try XCTUnwrap(converter)
        defer { AudioConverterDispose(conv) }

        let context = CaptureContext(
            converter: conv,
            nativeFormat: nativeFormat,
            targetFormat: targetFormat,
            wavWriter: nil,
            pcmSink: nil,
            listenSink: { _ in },
            levelCallback: { _ in }
        )
        var samples = [Float](repeating: 0.1, count: 1024)
        func feed() {
            samples.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                withUnsafePointer(to: &bufferList) { context.processAudio(inputBuffer: $0) }
            }
        }

        feed()
        XCTAssertEqual(context.deliveryCounts.inputBuffers, 1)
        XCTAssertEqual(context.deliveryCounts.recordedBytes, 0)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("first-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = WavWriter(url: url)
        try writer.open()
        context.beginRecording(wavWriter: writer, pcmSink: nil, includePreRoll: false)
        feed()
        XCTAssertEqual(context.deliveryCounts.inputBuffers, 2)
        XCTAssertGreaterThan(context.deliveryCounts.recordedBytes, 0)
        XCTAssertEqual(context.deliveryCounts.recordedBytes, writer.currentByteCount)
        try writer.finalize()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
