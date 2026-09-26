import AppKit
import Foundation

// NSWindow-based overlay at bottom-center of main screen.
// Shows a blue diffused ellipse glow (1000×60pt) that pulses with live mic input level.
// Turns red when recordingTimedOut is set to true.
@MainActor
public final class RecordingIndicator {

    public var isEnabled: Bool = true

    public var recordingTimedOut: Bool = false {
        didSet { updateColor() }
    }

    public init() {
        setupWindow()
    }

    public func show() {
        guard isEnabled else { return }
        window.orderFrontRegardless()
        startBreathing()
    }

    public func hide() {
        stopBreathing()
        window.orderOut(nil)
        recordingTimedOut = false
    }

    // Drives the glow alpha from live mic level (0.0-1.0). Smoothed so it reads as a
    // pulse rather than flickering frame-to-frame with raw RMS noise. Square-root curve
    // makes quiet speech visibly brighten the glow instead of clustering near the floor.
    public func updateLevel(_ level: Float) {
        let normalized = min(max(level, 0), 1)
        let perceptual = sqrt(normalized)
        targetAlpha = CGFloat(0.3 + 0.7 * perceptual)
    }

    // MARK: - Private

    private var window: NSWindow!
    private var glowView: GlowView!
    private var breathingTimer: Timer?
    private var targetAlpha: CGFloat = 0.3

    private func setupWindow() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let windowWidth: CGFloat = 1000
        let windowHeight: CGFloat = 60
        let xPos = screenFrame.midX - windowWidth / 2
        let yPos = screenFrame.minY

        let frame = NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight)

        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.hasShadow = false
        win.backgroundColor = .clear
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false

        let glow = GlowView(frame: NSRect(origin: .zero, size: frame.size))
        win.contentView = glow
        self.window = win
        self.glowView = glow
    }

    private func startBreathing() {
        targetAlpha = 0.3
        glowView.currentAlpha = 0.3
        breathingTimer?.invalidate()
        breathingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(breathingTimer!, forMode: .common)
    }

    private func stopBreathing() {
        breathingTimer?.invalidate()
        breathingTimer = nil
    }

    private func tick() {
        // Ease toward the latest mic-level target so updates (arriving in ~50ms bursts
        // from AudioRecorder's RMS interval) read as a smooth pulse, not a step function.
        // Higher smoothing factor than before so the glow tracks voice level more reactively.
        glowView.currentAlpha += (targetAlpha - glowView.currentAlpha) * 0.5
        glowView.needsDisplay = true
    }

    private func updateColor() {
        glowView.timedOut = recordingTimedOut
        glowView.needsDisplay = true
    }
}

// MARK: - GlowView

private final class GlowView: NSView {
    var currentAlpha: CGFloat = 0.3
    var timedOut: Bool = false

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let color: NSColor = timedOut
            ? NSColor(calibratedRed: 1.0, green: 0.15, blue: 0.15, alpha: 1.0)
            : NSColor(calibratedRed: 0.2, green: 0.55, blue: 1.0, alpha: 1.0)
        guard let rgbColor = color.usingColorSpace(.deviceRGB) else { return }

        // True radial gradient from a bright core to transparent edges, scaled into an
        // ellipse via a non-uniform CTM so the glow reads as wide-and-flat (1000x60 window).
        let width = bounds.width
        let height = bounds.height * 2
        let centerX = bounds.midX
        let centerY: CGFloat = 0
        let radius = width / 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let stopColors: [CGFloat] = [
            rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent, currentAlpha,
            rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent, currentAlpha * 0.8,
            rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent, 0.0,
        ]
        let locations: [CGFloat] = [0.0, 0.55, 1.0]
        guard let gradient = CGGradient(
            colorSpace: colorSpace,
            colorComponents: stopColors,
            locations: locations,
            count: locations.count
        ) else { return }

        ctx.saveGState()
        ctx.translateBy(x: centerX, y: centerY)
        ctx.scaleBy(x: 1.0, y: height / width)
        ctx.translateBy(x: -centerX, y: -centerY)
        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: centerX, y: centerY),
            startRadius: 0,
            endCenter: CGPoint(x: centerX, y: centerY),
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    override var isOpaque: Bool { false }
}
