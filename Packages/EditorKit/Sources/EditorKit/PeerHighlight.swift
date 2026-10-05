import AppKit

/// What the other pane has selected (PLAN M2, two-way selection), drawn over the text: an overlay view, not a text attribute, so it
/// adds no undo step, makes no styling pass and cannot end an input method's composition. It sits on top of the text in a
/// translucent colour; clicks go through it. Only the part of the ranges that is laid out where it draws is ever looked at, so a
/// highlight over a whole long document costs what the screen shows.
final class PeerHighlightView: NSView {
    weak var textView: NSTextView?
    private(set) var ranges: [NSRange] = []
    static let color = NSColor.systemYellow.withAlphaComponent(0.32)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// New ranges: only where the old and the new ones are on screen is drawn again.
    func show(_ new: [NSRange]) {
        guard new != ranges else { return }
        let old = rects(in: visibleRect)
        ranges = new
        for rect in old + rects(in: visibleRect) { setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
    }

    /// The text view was resized (wrapping moved the text under the ranges).
    @objc func layoutMoved(_ note: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Self.color.setFill()
        for rect in rects(in: dirtyRect) { rect.fill(using: .sourceOver) }
    }

    /// The highlight's rectangles inside `area` (view coordinates): the ranges cut to the characters laid out there, one per line
    /// fragment they cross. Nothing when that part of the text is not laid out (it is not on screen either).
    func rects(in area: NSRect) -> [NSRect] {
        guard !ranges.isEmpty, let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let length = textView.textStorage?.length, !area.isEmpty else { return [] }
        let origin = textView.textContainerOrigin
        func offset(_ location: NSTextLocation) -> Int { content.offset(from: content.documentRange.location, to: location) }
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, area.minY - origin.y))) else { return [] }
        let lastFragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, area.maxY - origin.y)))
        let shown = NSRange(location: offset(first.rangeInElement.location), length: 0)
        let end = lastFragment.map { offset($0.rangeInElement.endLocation) } ?? min(length, shown.location + 65_536)  // lazy: past the laid-out end, at most 64 K units
        let window = NSRange(location: shown.location, length: max(0, min(end, length) - shown.location))
        var out: [NSRect] = []
        for range in ranges {
            let part = NSIntersectionRange(range, window)
            guard part.length > 0, let start = content.location(content.documentRange.location, offsetBy: part.location),
                  let stop = content.location(start, offsetBy: part.length), let textRange = NSTextRange(location: start, end: stop) else { continue }
            layout.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if rect.width > 0, rect.height > 0, rect.intersects(area) { out.append(rect) }
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
            NotificationCenter.default.addObserver(view, selector: #selector(PeerHighlightView.layoutMoved(_:)), name: NSView.frameDidChangeNotification, object: self)
            return view
        }()
        if overlay.frame != bounds { overlay.frame = bounds }
        overlay.show(shown)
    }

    public func clearPeerHighlight() {
        peerHighlightView?.show([])
    }

    /// What `showPeerHighlight` last showed (empty when cleared).
    public var peerHighlightRanges: [NSRange] { peerHighlightView?.ranges ?? [] }

    /// The highlight's rectangles on screen, in view coordinates (tests).
    var peerHighlightRects: [NSRect] { peerHighlightView.map { $0.rects(in: visibleRect) } ?? [] }
}
