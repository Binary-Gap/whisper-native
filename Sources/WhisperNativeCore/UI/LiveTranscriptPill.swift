import AppKit

// Overlay showing the live transcript while recording with Parakeet, placed near
// the text input located at recording start (TextInputAnchor) and fixed there
// for the whole recording. Same look as LanguageHUD (borderless, click-through,
// .hudWindow blur), sized to the text and growing with it; the oldest words
// drop only once it runs out of screen.
@MainActor
public final class LiveTranscriptPill {

    public init() {
        setupWindow()
    }

    /// Sets where the pill sits for the current recording; cleared by hide().
    public func setAnchor(_ anchor: TextInputAnchor) {
        self.anchor = anchor
    }

    /// Shows the pill (if hidden) with the latest transcript. Empty text is ignored
    /// so a silent stretch keeps the last words on screen.
    public func update(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let placement = currentPlacement()
        label.stringValue = tail(of: trimmed, fittingHeight: placement.availableHeight)
        window.setFrame(placement.frame(for: fittedSize()), display: true)
        window.invalidateShadow()
        // Set alpha directly: alphaValue animations on this LSUIElement app's
        // windows silently skip (see LanguageHUD).
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    public func hide() {
        window.alphaValue = 0
        window.orderOut(nil)
        label.stringValue = ""
        anchor = .screenBottom
    }

    // MARK: - Private

    private static let maxWidth: CGFloat = 640
    private static let horizontalPadding: CGFloat = 20
    private static let verticalPadding: CGFloat = 12
    // Clears the RecordingIndicator glow band (60pt tall, anchored to screen bottom).
    private static let bottomMargin: CGFloat = 78
    // Space between the pill and the line or window edge it hangs off.
    private static let anchorGap: CGFloat = 8
    private static let cornerRadius: CGFloat = 18

    private var anchor: TextInputAnchor = .screenBottom

    private var window: NSWindow!
    private var label: NSTextField!

    private func setupWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 44),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.hasShadow = true
        win.backgroundColor = .clear
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.alphaValue = 0

        let blur = NSVisualEffectView(frame: win.contentLayoutRect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.cornerRadius
        // The window server shapes the material (and so the window shadow) from
        // maskImage only; the layer's corner radius alone leaves a square shadow.
        blur.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        // Border + window shadow keep the pill distinct over any background.
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.3).cgColor
        blur.autoresizingMask = [.width, .height]

        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .systemFont(ofSize: 15, weight: .regular)
        text.textColor = .labelColor
        text.alignment = .left
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byWordWrapping
        text.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPadding),
            text.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPadding),
            text.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])

        win.contentView = blur
        window = win
        label = text
    }

    // Stretchable rounded rect: cap insets keep the corners fixed as the pill resizes.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Fixed start point for one recording: the pill keeps its left edge and
    /// the edge facing the anchor, and grows away from it.
    private struct Placement {
        enum Growth { case downFrom(top: CGFloat), upFrom(bottom: CGFloat) }
        let left: CGFloat
        let growth: Growth
        let availableHeight: CGFloat
        let bounds: NSRect

        func frame(for size: NSSize) -> NSRect {
            let y: CGFloat = switch growth {
            case .downFrom(let top): top - size.height
            case .upFrom(let bottom): bottom
            }
            var frame = NSRect(x: left, y: y, width: size.width, height: size.height)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
            return frame
        }
    }

    private func currentPlacement() -> Placement {
        switch anchor {
        case .line(let line):
            let visible = visibleFrame(containing: line)
            let left = stableLeftEdge(preferred: line.minX - Self.horizontalPadding, in: visible)
            // Below the line, growing down, unless there's more room above
            // (a prompt near the screen bottom). Decided once per recording, so
            // the pill never jumps sides as it grows.
            let roomBelow = line.minY - Self.anchorGap - (visible.minY + Self.bottomMargin)
            let roomAbove = visible.maxY - (line.maxY + Self.anchorGap)
            if roomBelow >= roomAbove {
                return Placement(left: left, growth: .downFrom(top: line.minY - Self.anchorGap),
                                 availableHeight: roomBelow, bounds: visible)
            }
            return Placement(left: left, growth: .upFrom(bottom: line.maxY + Self.anchorGap),
                             availableHeight: roomAbove, bounds: visible)
        case .windowBottom(let windowFrame):
            let visible = visibleFrame(containing: windowFrame)
            let bottom = max(windowFrame.minY + Self.anchorGap * 2, visible.minY + Self.bottomMargin)
            return Placement(left: stableLeftEdge(preferred: windowFrame.midX - Self.maxWidth / 2, in: visible),
                             growth: .upFrom(bottom: bottom),
                             availableHeight: visible.maxY - bottom, bounds: visible)
        case .screenBottom:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                ?? NSScreen.main
                ?? NSScreen.screens[0]
            let bottom = screen.frame.minY + Self.bottomMargin
            return Placement(left: screen.frame.midX - Self.maxWidth / 2,
                             growth: .upFrom(bottom: bottom),
                             availableHeight: screen.visibleFrame.maxY - bottom, bounds: screen.frame)
        }
    }

    /// The whole transcript while it fits; once the pill would run out of screen,
    /// the oldest words drop (cut at a word boundary) so the newest stay visible.
    private func tail(of text: String, fittingHeight availableHeight: CGFloat) -> String {
        label.stringValue = text
        guard fittedSize().height > availableHeight else { return text }
        var words = text.split(separator: " ")
        while words.count > 1 {
            words.removeFirst(max(1, words.count / 10))
            let candidate = "…" + words.joined(separator: " ")
            label.stringValue = candidate
            if fittedSize().height <= availableHeight { return candidate }
        }
        return "…" + words.joined(separator: " ")
    }

    // Sized to the text, capped at maxWidth.
    private func fittedSize() -> NSSize {
        let textWidthLimit = Self.maxWidth - 2 * Self.horizontalPadding
        let fitted = label.sizeThatFits(NSSize(width: textWidthLimit, height: .greatestFiniteMagnitude))
        let width = min(ceil(fitted.width), textWidthLimit) + 2 * Self.horizontalPadding
        return NSSize(width: width, height: ceil(fitted.height) + 2 * Self.verticalPadding)
    }

    private func visibleFrame(containing rect: CGRect) -> NSRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        return screen.visibleFrame
    }

    // Left edge that stays put as the pill grows: text grows rightward from a
    // fixed start instead of re-centering on every word. Clamped against the
    // full maxWidth so the widest pill still fits on screen.
    private func stableLeftEdge(preferred: CGFloat, in bounds: NSRect) -> CGFloat {
        min(max(preferred, bounds.minX), bounds.maxX - Self.maxWidth)
    }

}
