import AppKit
import AVFoundation
import CoreAudio
import Foundation

// AudioRecorder captures microphone input and writes 16kHz mono 16-bit PCM WAV files.
// Primary path: CoreAudio AudioDeviceIOProc (works with Continuity Camera mics where
// AVAudioEngine fails). AVAudioEngine used as secondary validation only.
@MainActor
public final class AudioRecorder: AudioRecording {

    // MARK: - Public API

    public var isRecording: Bool { recordingState == .recording }
    public var onRecordingFailed: (@Sendable (AppError) -> Void)?

    // Callback fired on the main thread with linear audio level in 0.0–1.0 range.
    // Stored as a plain Sendable closure (not @MainActor-typed): the audio IO thread must
    // capture it without touching MainActor-isolated state, then dispatch to main itself.
    public var onLevelUpdate: (@Sendable (Float) -> Void)?

    // UID of the preferred input device (Config.inputDeviceUID). Nil = system default.
    public var preferredInputDeviceUID: String?

    // Whether to play start/stop cue sounds (Config.soundFeedback).
    public var soundFeedbackEnabled: Bool = true

    // Playback volume for cue sounds, 0.0–1.0 (Config.soundVolume).
    public var soundVolume: Float = 0.5

    public init() {}

    /// Lists CoreAudio devices that expose at least one input channel, for the Settings picker.
    public static func listInputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID) else { return nil }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Resolves a device UID back to its current AudioDeviceID, re-scanning live devices
    /// (UIDs aren't usable directly as AudioObjectPropertyAddress selectors).
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }
        return deviceIDs.first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        return bufferList.pointee.mNumberBuffers > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    public func startRecording(to path: URL) async throws {
        guard recordingState == .idle else {
            throw AppError.recordingFailed("Already recording")
        }

        try await requestMicPermission()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = WavWriter(url: path)
        try writer.open()
        self.wavWriter = writer
        self.outputURL = path

        try startCoreAudioCapture()

        // Let the mic settle to full level before cueing the user to speak, so
        // the first word isn't captured into the warmup ramp.
        try? await Task.sleep(nanoseconds: UInt64(Constants.micWarmupDelay * 1_000_000_000))

        recordingState = .recording

        playSound(named: "Blow")

        // Recording timeout watchdog.
        let timeout = Double(Constants.recordingTimeoutSeconds)
        timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await MainActor.run {
                guard let self, self.isRecording else { return }
                self.recordingState = .idle
                self.teardownCoreAudio()
                self.indicator?.recordingTimedOut = true
                let error = AppError.recordingFailed("Recording timed out after \(Int(timeout))s")
                self.onRecordingFailed?(error)
                AppLogger.shared.log(.warning, "Recording timed out")
            }
        }
    }

    public func stopRecording() async throws -> URL {
        guard recordingState == .recording, let url = outputURL else {
            throw AppError.recordingFailed("Not recording")
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        recordingState = .idle

        teardownCoreAudio()

        guard let writer = wavWriter else {
            throw AppError.recordingFailed("WAV writer missing")
        }
        try writer.finalize()
        wavWriter = nil

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        if size < Constants.minValidAudioBytes {
            throw AppError.audioFileTooSmall(size)
        }

        playSound(named: "Pop")
        AppLogger.shared.log(.info, "Recording stopped, WAV size=\(size) path=\(url.path)")

        outputURL = nil
        return url
    }

    // Attach the recording indicator so the recorder can set recordingTimedOut.
    public weak var indicator: RecordingIndicator?

    // MARK: - Private state

    private enum RecordingState { case idle, recording }
    private var recordingState: RecordingState = .idle
    private var wavWriter: WavWriter?
    private var outputURL: URL?
    private var timeoutTask: Task<Void, Error>?

    // CoreAudio
    private var audioDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var audioConverter: AudioConverterRef?
    private var ioProcID: AudioDeviceIOProcID?
    // Shared with the IO proc via Unmanaged; access guarded by the audio thread.
    private var sharedContext: CaptureContext?

    // MARK: - CoreAudio setup

    private func startCoreAudioCapture() throws {
        let deviceID = try resolveInputDevice()
        audioDeviceID = deviceID

        // Query native device format.
        var nativeFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &propSize, &nativeFormat)
        guard status == noErr else {
            throw AppError.recordingFailed("Failed to query device format: \(status)")
        }
        AppLogger.shared.log(.info, "Native device format: \(nativeFormat.mSampleRate)Hz ch=\(nativeFormat.mChannelsPerFrame)")

        // Target: 16kHz mono 16-bit PCM signed integer (native-endian for CoreAudio, will swap to LE for WAV).
        var targetFormat = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Build an AudioConverter from native → target if needed.
        var converter: AudioConverterRef?
        let converterStatus = AudioConverterNew(&nativeFormat, &targetFormat, &converter)
        guard converterStatus == noErr, let conv = converter else {
            throw AppError.recordingFailed("AudioConverterNew failed: \(converterStatus)")
        }
        audioConverter = conv

        // Create capture context (class instance, ref-counted).
        let ctx = CaptureContext(
            converter: conv,
            nativeFormat: nativeFormat,
            targetFormat: targetFormat,
            wavWriter: wavWriter!,
            // Snapshot the Sendable callback now (on main). The audio IO thread closure
            // must NOT capture `self` (MainActor-isolated): touching it there triggers
            // swift_task_isCurrentExecutor -> dispatch_assert_queue -> SIGTRAP, since the
            // realtime IO thread is not a dispatch queue.
            levelCallback: { [levelHandler = onLevelUpdate] rms in
                guard let levelHandler else { return }
                DispatchQueue.main.async {
                    levelHandler(rms)
                }
            }
        )
        sharedContext = ctx

        // Register and start IO proc. Use Unmanaged to pass the class instance through
        // the C-function-pointer-based AudioDeviceIOProcIDWithBlock callback.
        let ctxPtr = Unmanaged.passRetained(ctx)
        var procID: AudioDeviceIOProcID?
        // The IO block runs on CoreAudio's realtime IO thread (queue arg = nil). It MUST be
        // @Sendable: declared inside this @MainActor func, a non-Sendable block would inherit
        // main-actor isolation and the compiler inserts an executor-isolation check at entry
        // (swift_task_isCurrentExecutor -> dispatch_assert_queue), which traps on the IO thread
        // since it is not a dispatch queue → SIGTRAP. Capture only the Unmanaged ctx pointer.
        let ioBlock: @convention(block) @Sendable (
            UnsafePointer<AudioTimeStamp>,
            UnsafePointer<AudioBufferList>,
            UnsafePointer<AudioTimeStamp>,
            UnsafeMutablePointer<AudioBufferList>,
            UnsafePointer<AudioTimeStamp>
        ) -> Void = { _, inInputData, _, _, _ in
            let context = ctxPtr.takeUnretainedValue()
            context.processAudio(inputBuffer: inInputData)
        }
        var addStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, ioBlock)
        guard addStatus == noErr, let pid = procID else {
            ctxPtr.release()
            throw AppError.recordingFailed("AudioDeviceCreateIOProcID failed: \(addStatus)")
        }
        ioProcID = pid

        // Boost input gain to max before starting capture, so the very first
        // captured frames are already at full gain (setting it after start
        // leaves the opening ~fraction of a second recorded at the device's
        // prior, lower gain).
        setInputGainMax(deviceID: deviceID)

        addStatus = AudioDeviceStart(deviceID, pid)
        guard addStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid)
            ctxPtr.release()
            throw AppError.recordingFailed("AudioDeviceStart failed: \(addStatus)")
        }

        AppLogger.shared.log(.info, "CoreAudio capture started on device \(deviceID)")
    }

    private func teardownCoreAudio() {
        if audioDeviceID != kAudioObjectUnknown, let pid = ioProcID {
            AudioDeviceStop(audioDeviceID, pid)
            AudioDeviceDestroyIOProcID(audioDeviceID, pid)
            ioProcID = nil
        }
        audioDeviceID = kAudioObjectUnknown

        if let conv = audioConverter {
            AudioConverterDispose(conv)
            audioConverter = nil
        }

        sharedContext = nil
    }

    // MARK: - Device resolution

    private func resolveInputDevice() throws -> AudioDeviceID {
        // If a preferred device UID is configured and still connected, use it.
        // Resolved by re-scanning input devices (simpler/safer than the
        // AudioValueTranslation C-struct dance for kAudioHardwarePropertyDeviceForUID).
        if let uid = preferredInputDeviceUID,
           let deviceID = Self.deviceID(forUID: uid) {
            AppLogger.shared.log(.info, "Using preferred input device UID: \(uid)")
            return deviceID
        } else if preferredInputDeviceUID != nil {
            AppLogger.shared.log(.warning, "Preferred input device UID not found, falling back to default")
        }

        // Fall back to system default input device.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AppError.recordingFailed("No input device found: \(status)")
        }
        return deviceID
    }

    private func setInputGainMax(deviceID: AudioDeviceID) {
        var gain: Float32 = 1.0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &gain)
    }

    // MARK: - Mic permission

    private func requestMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw AppError.recordingFailed("Microphone access denied")
            }
        case .denied, .restricted:
            throw AppError.recordingFailed("Microphone access denied — enable in System Settings > Privacy > Microphone")
        @unknown default:
            throw AppError.recordingFailed("Unknown microphone authorization status")
        }
    }

    // MARK: - Sounds

    private func playSound(named name: String) {
        guard soundFeedbackEnabled else { return }
        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }
}

// MARK: - CaptureContext (heap-allocated, accessed from CoreAudio IO thread)

// This is NOT an actor. It's accessed from the CoreAudio IO thread and must be
// reference-safe via its own internal design (write-once fields, no shared mutable state
// beyond the wavWriter which serialises its own writes via the IO thread ordering).
// Passed to the AudioConverter input proc via userData. Lets the proc serve the captured
// input buffer exactly once per FillComplexBuffer call, then report end-of-input.
private struct InputProcState {
    var abl: AudioBufferList
    var framesPerPacket: UInt32
    var inputFrameCount: UInt32
    var consumed: Bool
}

final class CaptureContext: @unchecked Sendable {
    let converter: AudioConverterRef
    let nativeFormat: AudioStreamBasicDescription
    let targetFormat: AudioStreamBasicDescription
    let wavWriter: WavWriter
    let levelCallback: (Float) -> Void

    // Conversion output scratch buffer (reused across calls).
    private var conversionBuffer = [Int16](repeating: 0, count: 4096)
    private var levelAccum: Float = 0
    private var levelCount: Int = 0
    private static let levelIntervalSamples = 1600

    init(
        converter: AudioConverterRef,
        nativeFormat: AudioStreamBasicDescription,
        targetFormat: AudioStreamBasicDescription,
        wavWriter: WavWriter,
        levelCallback: @escaping (Float) -> Void
    ) {
        self.converter = converter
        self.nativeFormat = nativeFormat
        self.targetFormat = targetFormat
        self.wavWriter = wavWriter
        self.levelCallback = levelCallback
    }

    func processAudio(inputBuffer: UnsafePointer<AudioBufferList>) {
        let abl = inputBuffer.pointee
        guard abl.mNumberBuffers > 0 else { return }

        let buffer = withUnsafePointer(to: abl.mBuffers) { ptr -> AudioBuffer in
            ptr.pointee
        }
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }

        // Number of frames in this buffer based on native format.
        let bytesPerNativeFrame = max(1, Int(nativeFormat.mBytesPerFrame))
        let frameCount = Int(buffer.mDataByteSize) / bytesPerNativeFrame
        guard frameCount > 0 else { return }

        // Fill input buffer descriptor for the converter.
        var inputABL = AudioBufferList()
        inputABL.mNumberBuffers = 1
        inputABL.mBuffers.mData = UnsafeMutableRawPointer(mutating: data)
        inputABL.mBuffers.mDataByteSize = buffer.mDataByteSize
        inputABL.mBuffers.mNumberChannels = nativeFormat.mChannelsPerFrame

        // Output capacity, in target frames. At 16kHz vs 48kHz native this is ~frameCount/3,
        // but size generously (frameCount) so the converter is never output-bound.
        if conversionBuffer.count < frameCount {
            conversionBuffer = [Int16](repeating: 0, count: frameCount)
        }

        // Input-proc state: serve the captured input buffer exactly ONCE, then report
        // zero packets so the converter stops instead of re-reading the same frames
        // (re-reading inflated output 3x → 48kHz audio written at a 16kHz header).
        var inputProcState = InputProcState(
            abl: inputABL,
            framesPerPacket: max(1, nativeFormat.mFramesPerPacket),
            inputFrameCount: UInt32(frameCount),
            consumed: false
        )

        var writtenSamples = 0
        conversionBuffer.withUnsafeMutableBytes { rawPtr in
            var outputABL = AudioBufferList()
            outputABL.mNumberBuffers = 1
            outputABL.mBuffers.mData = rawPtr.baseAddress
            outputABL.mBuffers.mDataByteSize = UInt32(rawPtr.count)
            outputABL.mBuffers.mNumberChannels = 1

            // Ask for as many output frames as the buffer can hold; the converter
            // returns the actual count produced from the single input chunk.
            var ioOutputFrames = UInt32(rawPtr.count / 2)

            let status = AudioConverterFillComplexBuffer(
                converter,
                { _, ioPackets, ioData, _, userData in
                    guard let userData else { ioPackets.pointee = 0; return OSStatus(1) }
                    let state = userData.assumingMemoryBound(to: InputProcState.self)
                    if state.pointee.consumed {
                        ioPackets.pointee = 0
                        return OSStatus(1) // end of available input
                    }
                    state.pointee.consumed = true
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers = state.pointee.abl.mBuffers
                    // Packets = frames / framesPerPacket (1 for PCM).
                    ioPackets.pointee = state.pointee.inputFrameCount / state.pointee.framesPerPacket
                    return noErr
                },
                &inputProcState,
                &ioOutputFrames,
                &outputABL,
                nil
            )
            // status 1 is our own end-of-input sentinel, not a real error.
            if status == noErr || status == 1 {
                writtenSamples = Int(ioOutputFrames)
            }
        }

        guard writtenSamples > 0 else { return }

        // Write to WAV (little-endian; Int16 on Apple Silicon / x86 is already LE).
        let samples = conversionBuffer.prefix(writtenSamples)

        // Level metering (RMS).
        for sample in samples {
            let normalized = Float(sample) / 32768.0
            levelAccum += normalized * normalized
            levelCount += 1
        }
        if levelCount >= Self.levelIntervalSamples {
            let rms = sqrt(levelAccum / Float(levelCount))
            levelCallback(min(rms * 3.0, 1.0)) // scale up for visual feedback
            levelAccum = 0
            levelCount = 0
        }

        let outputData = conversionBuffer.prefix(writtenSamples).withUnsafeBytes { Data($0) }
        wavWriter.appendData(outputData)
    }
}
