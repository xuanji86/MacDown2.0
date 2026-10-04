import AppKit

/// One line number to draw. Coordinates are the text view's.
struct LineMark: Equatable {
    var number: Int  // 1-based source line
    var baseline: CGFloat  // of the first visual row of the line
    var top: CGFloat  // of the whole line, i.e. including its wrapped rows
    var height: CGFloat
    var isCurrent: Bool
}

extension MarkdownTextView {
    /// The line numbers for the layout fragments (= source lines) that intersect `rect`, in the text view's coordinates.
    /// A soft-wrapped line is one fragment with several visual rows and gets one mark, on its first row. Only the visible
    /// fragments are touched; the first one's number costs a newline count up to it (memchr-speed, see `lineIndex`).
    func lineMarks(in rect: NSRect) -> [LineMark] {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return [] }
        let originY = textContainerOrigin.y
        let length = textStorage?.length ?? 0
        let caret = min(selectedRange().location, length)
        if length == 0 { return emptyLineMark(in: layout, isCurrent: true, number: 1).map { [$0] } ?? [] }
        let top = max(0, rect.minY - originY), bottom = rect.maxY - originY
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return [] }
        let docStart = content.documentRange.location
        let text = textStorage?.mutableString ?? NSMutableString()

        var marks: [LineMark] = []
        var number = lineIndex(atOffset: content.offset(from: docStart, to: first.rangeInElement.location)) + 1
        layout.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > bottom { return false }
            let start = content.offset(from: docStart, to: fragment.rangeInElement.location)
            let end = content.offset(from: docStart, to: fragment.rangeInElement.endLocation)
            let endsLine = end > start && text.character(at: end - 1) == 0x0A
            // The caret belongs to the line whose text it is in; at the very end it belongs to the last line, unless
            // that ends in a newline: then to the empty line after it.
            let isCurrent = caret >= start && (caret < end || (caret == end && !endsLine))
            let rows = fragment.textLineFragments
            let row = rows.first
            var height = frame.height
            // After a final newline TextKit puts the empty last line into the same fragment, as an extra empty row.
            var extra: NSTextLineFragment?
            if end == length, endsLine, rows.count > 1, let last = rows.last, last.characterRange.length == 0 {
                extra = last
                height = last.typographicBounds.minY
            }
            let baseline = frame.minY + (row?.typographicBounds.minY ?? 0) + (row?.glyphOrigin.y ?? 0)
            marks.append(LineMark(number: number, baseline: baseline + originY, top: frame.minY + originY, height: height, isCurrent: isCurrent))
            number += 1
            if let extra {
                let rowTop = frame.minY + extra.typographicBounds.minY
                marks.append(LineMark(
                    number: number, baseline: rowTop + extra.glyphOrigin.y + originY, top: rowTop + originY,
                    height: extra.typographicBounds.height, isCurrent: caret == length))
            }
            return true
        }
        return marks
    }

    /// The only line of an empty document: TextKit has no fragment for it, only the caret position.
    private func emptyLineMark(in layout: NSTextLayoutManager, isCurrent: Bool, number: Int) -> LineMark? {
        var mark: LineMark?
        layout.enumerateTextSegments(in: NSTextRange(location: layout.documentRange.endLocation), type: .standard, options: [.rangeNotRequired]) { _, frame, baseline, _ in
            let y = textContainerOrigin.y
            mark = LineMark(number: number, baseline: y + frame.minY + baseline, top: y + frame.minY, height: frame.height, isCurrent: isCurrent)
            return false
        }
        return mark
    }

    /// Source lines in the document (a trailing newline starts one more, empty line).
    var lineCount: Int { lineIndex(atOffset: textStorage?.length ?? 0) + 1 }
}

/// The line-number column (PLAN 4.3.1): an `NSRulerView` that draws only what is on screen. It never touches the text
/// system itself, it asks `MarkdownTextView.lineMarks`.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private static let padding: CGFloat = 8
    private static let minimumDigits = 3  // so the column does not jump at 100 lines
    private var recountScheduled = false
    private var digits = LineNumberRulerView.minimumDigits

    private var textView: MarkdownTextView? { clientView as? MarkdownTextView }

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private func numberFont(for theme: EditorTheme) -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(theme.font.pointSize * 0.85, 8), weight: .regular)
    }

    /// Width for the digits of the current line count. Cheap to call; only resizes when the digit count changes.
    func updateThickness() {
        guard let textView else { return }
        let count = max(textView.lineCount, 1)
        digits = max(String(count).count, Self.minimumDigits)
        let digitWidth = NSAttributedString(string: "0", attributes: [.font: numberFont(for: textView.theme)]).size().width
        let width = ceil(CGFloat(digits) * digitWidth) + 2 * Self.padding
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    /// Text changed: redraw now, resize (a digit more or less) once the edit is done, outside `processEditing`.
    func textDidChange() {
        needsDisplay = true
        guard !recountScheduled else { return }
        recountScheduled = true
        DispatchQueue.main.async { MainActor.assumeIsolated { [self] in
            recountScheduled = false
            updateThickness()
        } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let theme = textView.theme
        theme.background.setFill()
        bounds.fill()
        theme.lineNumber.withAlphaComponent(0.25).setFill()
        NSRect(x: bounds.maxX - 0.5, y: bounds.minY, width: 0.5, height: bounds.height).fill()

        let font = numberFont(for: theme)
        let visible = textView.visibleRect
        for mark in textView.lineMarks(in: visible) {
            let y = convert(NSPoint(x: 0, y: mark.top), from: textView).y
            if mark.isCurrent {
                theme.currentLine.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: mark.height).fill()
            }
            let label = NSAttributedString(string: String(mark.number), attributes: [
                .font: font, .foregroundColor: mark.isCurrent ? theme.text : theme.lineNumber,
            ])
            let baseline = convert(NSPoint(x: 0, y: mark.baseline), from: textView).y
            // Right-aligned, sitting on the same baseline as the first row of the line.
            label.draw(at: NSPoint(x: bounds.width - Self.padding - label.size().width, y: isFlipped ? baseline - font.ascender : baseline - font.descender))
        }
    }
}
