import AVFoundation
import AppKit
import ApplicationServices
import WhisperNativeCore

// MARK: - MicrophonePermission

enum MicrophonePermission: Equatable {
    case notDetermined
    case granted
    case denied
}

// MARK: - PermissionsState

/// Live mic + accessibility grant status for the onboarding permissions step,
/// plus the actions to request/open the relevant System Settings pane.
/// Accessibility can only be granted by the user in System Settings, so this
/// polls while visible instead of relying on a notification.
@MainActor
final class PermissionsState: ObservableObject {
    @Published private(set) var microphone: MicrophonePermission
    @Published private(set) var accessibilityGranted: Bool

    // nonisolated(unsafe): cancelled from deinit (nonisolated) and otherwise only
    // touched on the main actor; deinit is the last use.
    nonisolated(unsafe) private var monitorTask: Task<Void, Never>?

    init() {
        microphone = Self.currentMicrophonePermission()
        accessibilityGranted = AXIsProcessTrusted()
    }

    deinit {
        monitorTask?.cancel()
    }

    /// Starts a 1-second repeating refresh of both grants. Idempotent: calling
    /// again while already monitoring restarts the loop.
    func startMonitoring() {
        stopMonitoring()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Requests the microphone permission via the system prompt. If already
    /// denied, the prompt never reappears, so this opens the Settings pane instead.
    func requestMicrophone() {
        if microphone == .denied {
            openMicrophoneSettings()
            return
        }
        Task { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            self?.refresh()
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fires the one-shot system Accessibility prompt (shown only the first time
    /// per app), then opens the Accessibility pane, which is the reliable path
    /// once the prompt has already fired once.
    func promptAccessibility() {
        // kAXTrustedCheckOptionPrompt is a non-Sendable global; its literal value
        // is the stable key AppKit expects, so use it directly (matches
        // HotkeyManager.requestAccessibilityIfNeeded()).
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openAccessibilitySettings()
    }

    // MARK: - Private

    private func refresh() {
        let newMicrophone = Self.currentMicrophonePermission()
        if newMicrophone != microphone {
            AppLogger.shared.log(.info, "Microphone permission changed: \(microphone) -> \(newMicrophone)")
            microphone = newMicrophone
        }

        let newAccessibilityGranted = AXIsProcessTrusted()
        if newAccessibilityGranted != accessibilityGranted {
            AppLogger.shared.log(.info, "Accessibility permission changed: \(accessibilityGranted) -> \(newAccessibilityGranted)")
            accessibilityGranted = newAccessibilityGranted
        }
    }

    private static func currentMicrophonePermission() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}
