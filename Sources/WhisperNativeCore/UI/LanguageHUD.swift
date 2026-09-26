import AppKit

// Transient bottom-center overlay confirming the current transcription language
// after the language hotkey fires. Mirrors the system volume/brightness HUD:
// borderless click-through window, fades in, holds briefly, fades out.
// Sits above the RecordingIndicator glow band so both can be on screen at once.
@MainActor
public final class LanguageHUD {

    public init() {
        setupWindow()
    }

    /// Show the pill for `code` (e.g. "PT") with `name` underneath. Re-showing
    /// while visible restarts the hold instead of stacking fades, so rapid cycling
    /// reads as one HUD updating in place.
    public func show(code: String, name: String) {
        codeLabel.stringValue = code
        nameLabel.stringValue = name
        window.setFrame(frameForCurrentScreen(), display: false)

        showGeneration &+= 1
        let generation = showGeneration

        hideWorkItem?.cancel()
        // Set alpha directly: an alphaValue animation on a background (LSUIElement)
        // app's window is unreliable — when it doesn't run, the window is on screen
        // but stays fully transparent. Appearing instantly also matches the system
        // volume/brightness HUDs.
        window.alphaValue = 1
        window.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.fadeOut(generation: generation) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
    }

    // MARK: - Private

    private static let fadeOutDuration: TimeInterval = 0.25
    private static let holdDuration: TimeInterval = 0.9
    private static let windowSize = NSSize(width: 150, height: 84)
    // Clears the RecordingIndicator glow band (60pt tall, anchored to screen bottom).
    private static let bottomMargin: CGFloat = 78

    private var window: NSWindow!
    private var codeLabel: NSTextField!
    private var nameLabel: NSTextField!
    private var hideWorkItem: DispatchWorkItem?
    // Bumped on every show so a fade-out that finishes after a newer show can't
    // tear down the window that show just put on screen.
    private var showGeneration = 0

    private func setupWindow() {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.hasShadow = false
        win.backgroundColor = .clear
        // Above LiveTranscriptPill (.floating), which shares the bottom-center spot.
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.alphaValue = 0

        // .hudWindow material keeps the pill legible over any wallpaper/app and
        // follows the system appearance for free.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.windowSize))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let code = Self.makeLabel(font: .systemFont(ofSize: 30, weight: .semibold), color: .labelColor)
        let name = Self.makeLabel(font: .systemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)

        let stack = NSStackView(views: [code, name])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])

        win.contentView = blur
        window = win
        codeLabel = code
        nameLabel = name
    }

    private static func makeLabel(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.alignment = .center
        return label
    }

    // Follows the screen the pointer is on, so the HUD shows up on the display
    // the user is working on rather than always on the primary one.
    private func frameForCurrentScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.frame
        return NSRect(
            x: visible.midX - Self.windowSize.width / 2,
            y: visible.minY + Self.bottomMargin,
            width: Self.windowSize.width,
            height: Self.windowSize.height
        )
    }

    // Fades out over `fadeOutDuration`, then force-clears the window state so a
    // skipped animation can't leave the pill stuck on screen or half-visible.
    private func fadeOut(generation: Int) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, generation == self.showGeneration else { return }
            self.window.alphaValue = 0
            self.window.orderOut(nil)
        }
    }
}
