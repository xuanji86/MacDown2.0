import AppKit

/// "Show invisibles" under TextKit 2. `NSLayoutManager.showsInvisibleCharacters` is TextKit 1 only (and touching the
/// layout manager would downgrade the view), and `NSTextView` has no equivalent, so the marks are drawn by the layout
/// fragment: after the normal drawing, one glyph per space, tab and line end, positioned with
/// `NSTextLineFragment.locationForCharacter`. Only fragments that are being drawn (the viewport) pay for it.
final class InvisiblesLayoutFragment: NSTextLayoutFragment {
    /// Asked at draw time, so toggling the setting only needs a redisplay, not a relayout.
    var marks: (() -> (enabled: Bool, color: NSColor, font: NSFont))?

    /// Room past the text for the line-end mark, which sits outside the glyphs' own bounds.
    private static let trailing: CGFloat = 40

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard marks?().enabled == true else { return bounds }
        return bounds.union(CGRect(x: 0, y: 0, width: layoutFragmentFrame.width + Self.trailing, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let style = marks?(), style.enabled else { return }
        let glyph: (UInt16) -> String? = {
            switch $0 {
            case 0x20: "·"
            case 0x09: "→"
            case 0x0A: "¶"
            default: nil
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.color]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for line in textLineFragments {
            let string = line.attributedString.string as NSString
            let range = line.characterRange
            let bounds = line.typographicBounds
            for i in range.location..<NSMaxRange(range) {
                guard let mark = glyph(string.character(at: i)) else { continue }
                let at = line.locationForCharacter(at: i)
                let label = NSAttributedString(string: mark, attributes: attributes)
                var x = point.x + bounds.minX + at.x
                if string.character(at: i) == 0x20 {  // centred in the space's cell
                    let next = i + 1 < NSMaxRange(range) ? line.locationForCharacter(at: i + 1).x : at.x + label.size().width
                    x += max(0, (next - at.x - label.size().width) / 2)
                }
                // `at.y` is the baseline in the line fragment's space; the string is drawn from its top.
                label.draw(at: NSPoint(x: x, y: point.y + bounds.minY + at.y - style.font.ascender))
            }
        }
    }
}
