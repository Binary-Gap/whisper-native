import Foundation

@MainActor
public protocol AudioRecording: AnyObject {
    func startRecording(to path: URL) async throws
    func stopRecording() async throws -> URL
    var isRecording: Bool { get }
    var onRecordingFailed: (@Sendable (AppError) -> Void)? { get set }
    var preferredInputDeviceUID: String? { get set }
    var soundFeedbackEnabled: Bool { get set }
    var soundVolume: Float { get set }
}
