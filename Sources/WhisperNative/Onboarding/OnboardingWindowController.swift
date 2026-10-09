import AppKit
import SwiftUI
import WhisperNativeCore

// MARK: - OnboardingOutcome

/// How the onboarding window closed: finished (last step's Finish button) or
/// skipped (Skip on any earlier step, or the red close button).
enum OnboardingOutcome {
    case finished
    case skipped
}

// MARK: - OnboardingWindowController

/// Hosts `OnboardingView` in its own window. Marking the flow completed is
/// AppDelegate's job (in `onClose`), not this controller's: it only reports
/// how the window closed.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    private let navigation = OnboardingNavigation()
    private let permissions = PermissionsState()
    private let onClose: @MainActor (OnboardingOutcome) -> Void
    private var pendingOutcome: OnboardingOutcome?

    init(store: SettingsStore, modelSectionState: ModelSectionState, onClose: @escaping @MainActor (OnboardingOutcome) -> Void) {
        self.store = store
        self.onClose = onClose
        // NSWindowController's designated initializer must run before `self`
        // can be captured by the view's onFinish/onSkip closures below.
        super.init(window: nil)

        let view = OnboardingView(
            store: store,
            modelSectionState: modelSectionState,
            permissions: permissions,
            navigation: navigation,
            onFinish: { [weak self] in self?.close(with: .finished) },
            onSkip: { [weak self] in self?.close(with: .skipped) }
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Welcome to Whisper Native"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 680, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var isShowing: Bool { window?.isVisible == true }

    /// Always starts at the welcome step, whether this is the automatic
    /// first-run show or a reopen from "Setup Guide".
    func show() {
        navigation.step = .welcome
        // Force a Dock icon while onboarding is open so the window is
        // Cmd-Tabbable even when the app normally runs menu-bar-only.
        // Restored to the user's baseline in windowWillClose.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close(with outcome: OnboardingOutcome) {
        pendingOutcome = outcome
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.applyBaselineActivationPolicy(store.config)
        onClose(pendingOutcome ?? .skipped)
        pendingOutcome = nil
    }
}
