import AppKit

// Pure AppKit entry point (no SwiftUI @main lifecycle).
// LSUIElement: true is set in project.yml — no Dock icon, no app menu bar.
//
// Required Info.plist additions (via project.yml info.properties):
//   LSUIElement: true
//   NSMicrophoneUsageDescription: "Whisper Native needs microphone access to record audio for transcription."
//   NSAppleEventsUsageDescription: "Whisper Native uses AppleScript to paste transcribed text."
//
// Required entitlements (Hardened Runtime):
//   com.apple.security.device.audio-input: true
//   com.apple.security.automation.apple-events: true
//   (Accessibility permission is requested at runtime via AXIsProcessTrustedWithOptions)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
