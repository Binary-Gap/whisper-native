import AppKit
import ApplicationServices

/// Where the live transcript pill sits for one recording. Rects are in Cocoa
/// screen coordinates (origin at the primary screen's bottom-left).
public enum TextInputAnchor: Sendable, Equatable {
    /// The caret's line or a single-line focused field: the pill goes just below it.
    case line(CGRect)
    /// Focused window whose input can't be located: the pill sits inside its
    /// bottom edge, where terminal prompts and chat inputs live.
    case windowBottom(CGRect)
    /// Nothing located: bottom-center of the screen under the pointer.
    case screenBottom

    public var sourceName: String {
        switch self {
        case .line: "line"
        case .windowBottom: "window"
        case .screenBottom: "screen"
        }
    }
}

/// Finds the focused text input through the Accessibility API, trying in order:
/// caret rect -> focused element frame (small fields only) -> focused window ->
/// screen. Blocking AX IPC, so call it off the main thread.
public enum TextInputLocator {

    // Unresponsive apps would otherwise stall each AX call for the 6s default.
    private static let messagingTimeout: Float = 0.25
    // Focused elements taller than this are text areas, not a line to sit under.
    private static let maxLineElementHeight: CGFloat = 80

    public static func locate() -> TextInputAnchor {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        if let element: AXUIElement = copyAttribute(systemWide, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            if let caret = caretRect(of: element) {
                return .line(caret)
            }
            if let frame = frame(of: element), frame.height <= maxLineElementHeight {
                return .line(frame)
            }
        }
        if let app: AXUIElement = copyAttribute(systemWide, kAXFocusedApplicationAttribute) {
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            if let window: AXUIElement = copyAttribute(app, kAXFocusedWindowAttribute),
               let frame = frame(of: window) {
                return .windowBottom(frame)
            }
        }
        return .screenBottom
    }

    // MARK: - Private

    /// Bounds of the insertion point. Empty ranges return a zero rect in some
    /// apps, so it retries with the character before the caret.
    private static func caretRect(of element: AXUIElement) -> CGRect? {
        guard let rangeValue: AXValue = copyAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }

        var candidates = [range]
        if range.length == 0, range.location > 0 {
            candidates.append(CFRange(location: range.location - 1, length: 1))
        }
        for candidate in candidates {
            var mutableRange = candidate
            guard let candidateValue = AXValueCreate(.cfRange, &mutableRange) else { continue }
            var boundsRef: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, candidateValue, &boundsRef)
            guard status == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { continue }
            var bounds = CGRect.zero
            guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &bounds) else { continue }
            if let rect = validated(cocoaRect(fromAX: bounds)) { return rect }
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return validated(cocoaRect(fromAX: CGRect(origin: position, size: size)))
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // AX uses a top-left origin anchored to the primary screen's top edge.
    private static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // Rejects the zero/offscreen rects apps return when they don't really know.
    private static func validated(_ rect: CGRect) -> CGRect? {
        guard rect.height > 0, rect.width >= 0 else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return nil }
        return rect
    }
}
