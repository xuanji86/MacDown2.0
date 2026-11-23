import AppKit

/// Draws search match overlays over `MarkdownTextView` text without mutating text attributes or undo state.
@MainActor
final class FindHighlightView: NSView {
    weak var textView: MarkdownTextView?
    private(set) var ranges: [NSRange] = []
    private(set) var activeIndex: Int?
    private var painted: [NSRect] = []

    static let normalColor = NSColor.systemYellow.withAlphaComponent(0.35)
    static let activeColor = NSColor.systemOrange.withAlphaComponent(0.50)
    static let activeBorderColor = NSColor.systemOrange.withAlphaComponent(0.90)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(ranges: [NSRange], activeIndex: Int?) {
        guard ranges != self.ranges || activeIndex != self.activeIndex else { return }
        self.ranges = ranges
        self.activeIndex = activeIndex
        let dirty = painted + rects(in: visibleRect)
        painted = []
        for rect in dirty { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
    }

    @objc func layoutMoved(_ note: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard !ranges.isEmpty else { return }
        for (index, r) in ranges.enumerated() {
            let rRects = rects(for: r, in: dirtyRect)
            if index == activeIndex {
                Self.activeColor.setFill()
                Self.activeBorderColor.setStroke()
                for rect in rRects {
                    let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                    path.fill()
                    path.lineWidth = 1
                    path.stroke()
                    painted.append(rect)
                }
            } else {
                Self.normalColor.setFill()
                for rect in rRects {
                    rect.fill(using: .sourceOver)
                    painted.append(rect)
                }
            }
        }
        if painted.count > 512 { painted = [painted.reduce(NSRect.null) { $0.union($1) }] }
    }

    private func rects(in area: NSRect) -> [NSRect] {
        ranges.flatMap { rects(for: $0, in: area) }
    }

    private func rects(for range: NSRange, in area: NSRect) -> [NSRect] {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let length = textView.textStorage?.length, !area.isEmpty, range.length > 0 else { return [] }
        let origin = textView.textContainerOrigin
        func offset(_ location: NSTextLocation) -> Int { content.offset(from: content.documentRange.location, to: location) }
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, area.minY - origin.y))) else { return [] }
        let lastFragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, area.maxY - origin.y)))
        let shown = NSRange(location: offset(first.rangeInElement.location), length: 0)
        let end = lastFragment.map { offset($0.rangeInElement.endLocation) } ?? min(length, shown.location + 65_536)
        let window = NSRange(location: shown.location, length: max(0, min(end, length) - shown.location))
        let part = NSIntersectionRange(range, window)
        guard part.length > 0,
              let start = content.location(content.documentRange.location, offsetBy: part.location),
              let stop = content.location(start, offsetBy: part.length),
              let textRange = NSTextRange(location: start, end: stop) else { return [] }
        var out: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            if rect.width > 0, rect.height > 0, rect.intersects(area) { out.append(rect) }
            return true
        }
        return out
    }
}

extension MarkdownTextView {
    private var findHighlightView: FindHighlightView? { subviews.lazy.compactMap { $0 as? FindHighlightView }.first }

    /// Shows `ranges` as find matches; `activeIndex` is drawn with active accent styling. An empty list clears.
    public func showFindHighlights(_ ranges: [NSRange], activeIndex: Int?) {
        let shown = ranges.filter { $0.length > 0 }
        guard !shown.isEmpty else { return clearFindHighlights() }
        let overlay = findHighlightView ?? {
            let view = FindHighlightView(frame: bounds)
            view.textView = self
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            NotificationCenter.default.addObserver(view, selector: #selector(FindHighlightView.layoutMoved(_:)), name: NSView.frameDidChangeNotification, object: self)
            return view
        }()
        if overlay.frame != bounds { overlay.frame = bounds }
        overlay.show(ranges: shown, activeIndex: activeIndex)
    }

    public func clearFindHighlights() {
        findHighlightView?.show(ranges: [], activeIndex: nil)
    }

    /// What `showFindHighlights` last showed (empty when cleared).
    public var findHighlightRanges: [NSRange] { findHighlightView?.ranges ?? [] }
}
