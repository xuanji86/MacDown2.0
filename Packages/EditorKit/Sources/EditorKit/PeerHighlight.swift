import AppKit

/// What the other pane has selected (PLAN M2, two-way selection), drawn over the text: an overlay view, not a text attribute, so it
/// adds no undo step, makes no styling pass and cannot end an input method's composition. It sits on top of the text in a
/// translucent colour; clicks go through it.
final class PeerHighlightView: NSView {
    weak var textView: NSTextView?
    var ranges: [NSRange] = [] {
        didSet { if ranges != oldValue { needsDisplay = true } }
    }
    static let color = NSColor.systemYellow.withAlphaComponent(0.32)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The text view was resized (wrapping moved the text under the ranges).
    @objc func layoutMoved(_ note: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Self.color.setFill()
        for rect in rects() where rect.intersects(dirtyRect) { rect.fill(using: .sourceOver) }
    }

    /// The highlight's rectangles in the text view's coordinates (layout segments, so wrapped lines give one per line fragment).
    func rects() -> [NSRect] {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let length = textView.textStorage?.length else { return [] }
        let origin = textView.textContainerOrigin
        var out: [NSRect] = []
        for range in ranges {
            let lower = min(max(range.location, 0), length), upper = min(max(NSMaxRange(range), lower), length)
            guard upper > lower, let start = content.location(content.documentRange.location, offsetBy: lower),
                  let end = content.location(start, offsetBy: upper - lower), let textRange = NSTextRange(location: start, end: end) else { continue }
            layout.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
                if frame.width > 0, frame.height > 0 { out.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        return out
    }
}

extension MarkdownTextView {
    private var peerHighlightView: PeerHighlightView? { subviews.lazy.compactMap { $0 as? PeerHighlightView }.first }

    /// Shows `ranges` (UTF-16, in the text on screen) as the other pane's selection; replaces what was shown. An empty list clears.
    public func showPeerHighlight(_ ranges: [NSRange]) {
        let shown = ranges.filter { $0.length > 0 }
        guard !shown.isEmpty else { return clearPeerHighlight() }
        let overlay = peerHighlightView ?? {
            let view = PeerHighlightView(frame: bounds)
            view.textView = self
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            // Layout moves under a still range when the width changes (wrapping): draw again.
            NotificationCenter.default.addObserver(view, selector: #selector(PeerHighlightView.layoutMoved(_:)), name: NSView.frameDidChangeNotification, object: self)
            return view
        }()
        overlay.frame = bounds
        overlay.ranges = shown
        overlay.needsDisplay = true
    }

    public func clearPeerHighlight() {
        peerHighlightView?.ranges = []
    }

    /// What `showPeerHighlight` last showed (empty when cleared).
    public var peerHighlightRanges: [NSRange] { peerHighlightView?.ranges ?? [] }

    /// The highlight's rectangles in view coordinates (tests).
    var peerHighlightRects: [NSRect] { peerHighlightView?.rects() ?? [] }
}
