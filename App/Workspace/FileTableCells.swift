import AppKit
import WorkspaceKit

/// Colors and symbols of the tree (design 06: `folder.system` #4A9BE6, Quarto #6F8BE0).
enum SidebarStyle {
    static let folderTint = NSColor(srgbRed: 0x4A / 255, green: 0x9B / 255, blue: 0xE6 / 255, alpha: 1)
    static let quartoTint = NSColor(srgbRed: 0x6F / 255, green: 0x8B / 255, blue: 0xE0 / 255, alpha: 1)
    static let rowHeight: CGFloat = 24
    static let indent: CGFloat = 16

    static func symbol(_ name: String, size: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }
}

/// A borderless button that runs a closure (cells are rebuilt often; target/action plumbing per button is not worth it).
final class ActionButton: NSButton {
    var onClick: (() -> Void)?

    convenience init(symbol: String? = nil, title: String = "", onClick: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.onClick = onClick
        isBordered = false
        bezelStyle = .inline
        imagePosition = symbol == nil ? .noImage : .imageOnly
        if let symbol { image = SidebarStyle.symbol(symbol, size: 11) }
        self.title = title
        target = self
        action = #selector(fire)
        focusRingType = .none
        refusesFirstResponder = true  // the table keeps the keyboard
    }

    @objc private func fire() { onClick?() }
}

/// Row background: the active document's row is tinted even when another row has the selection.
final class SidebarRowView: NSTableRowView {
    var isActiveDocument = false { didSet { if oldValue != isActiveDocument { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isActiveDocument, !isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// A file, folder, favorite or recent: chevron (folders in the tree), icon, name, Quarto badge, unsaved dot.
final class FileCellView: NSTableCellView, NSTextFieldDelegate {
    private let chevron = ActionButton(symbol: "chevron.right")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "Q")
    private let dot = NSView()
    private let trailing = NSStackView()
    private var indent: NSLayoutConstraint!
    private var chevronWidth: NSLayoutConstraint!
    private var iconTint: NSColor = .secondaryLabelColor

    /// (new name or nil if cancelled)
    var onEnd: ((String?) -> Void)?
    private var endedByCommand = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.delegate = self
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = SidebarStyle.quartoTint.cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 16), badge.heightAnchor.constraint(equalToConstant: 14)])
        badge.toolTip = String(localized: "Quarto project (contains _quarto.yml)")

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
        dot.toolTip = String(localized: "Has unsaved changes")

        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.alignment = .centerY
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.addArrangedSubview(badge)
        trailing.addArrangedSubview(dot)

        for view in [chevron, icon, label, trailing] { addSubview(view) }
        indent = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 12)
        NSLayoutConstraint.activate([
            indent, chevronWidth,
            chevron.heightAnchor.constraint(equalToConstant: 16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -4),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    static let identifier = NSUserInterfaceItemIdentifier("file")

    struct Content {
        var name: String
        var symbol: String
        var tint: NSColor
        var depth = 0
        /// A tree row: files keep the chevron's room so their names line up with the folders'. Favorites and recents do not.
        var isTree = true
        var hasChevron = false
        var isExpanded = false
        var isQuarto = false
        var isDirty = false
        var isPreview = false
        var isDimmed = false
        var query = ""
        var help: String?
    }

    func configure(_ c: Content, toggle: @escaping () -> Void) {
        iconTint = c.tint
        icon.image = SidebarStyle.symbol(c.symbol)
        icon.contentTintColor = c.tint
        indent.constant = 4 + CGFloat(c.depth) * SidebarStyle.indent
        chevronWidth.constant = c.isTree ? 12 : 0
        chevron.isHidden = !c.hasChevron
        chevron.image = SidebarStyle.symbol(c.isExpanded ? "chevron.down" : "chevron.right", size: 9)
        chevron.onClick = toggle
        badge.isHidden = !c.isQuarto
        dot.isHidden = !c.isDirty
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        alphaValue = c.isDimmed ? 0.5 : 1
        toolTip = c.help
        setAccessibilityLabel(c.isDirty ? String(localized: "\(c.name), has unsaved changes") : c.name)

        var font = NSFont.systemFont(ofSize: 13)
        if c.isPreview { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }  // preview tab = italic, as in the tab bar
        let text = NSMutableAttributedString(string: c.name, attributes: [.font: font])
        if !c.query.isEmpty, let range = c.name.range(of: c.query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: NSRange(range, in: c.name))
        }
        label.attributedStringValue = text
        label.textColor = c.isPreview ? .secondaryLabelColor : .labelColor
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { icon.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : iconTint }
    }

    // MARK: Renaming in place

    func beginEditing(selectingBaseName: Bool) {
        guard let window else { return }
        endedByCommand = false
        label.isEditable = true
        label.isSelectable = true
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        label.textColor = .labelColor
        window.makeFirstResponder(label)
        if let editor = label.currentEditor() {
            let name = label.stringValue as NSString
            let dot = name.range(of: ".", options: .backwards)
            editor.selectedRange = selectingBaseName && dot.location != NSNotFound && dot.location > 0 ? NSRange(location: 0, length: dot.location) : NSRange(location: 0, length: name.length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        label.isEditable = false
        label.isSelectable = false
        guard !endedByCommand else { return }
        // Return ends editing with a text movement; clicking elsewhere ends it too and keeps what was typed.
        onEnd?(label.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endedByCommand = true
            label.isEditable = false
            label.isSelectable = false
            window?.makeFirstResponder(superview?.superview)
            onEnd?(nil)
            return true
        }
        return false
    }
}

/// Section title with its trailing control (+ / Clear / Reading…).
final class HeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("header")
    private let title = NSTextField(labelWithString: "")
    private let button = ActionButton(title: "")
    private let status = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        button.contentTintColor = .secondaryLabelColor
        for v in [title, button, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, trailing: SidebarItem.Trailing, action: @escaping () -> Void) {
        title.stringValue = text
        setAccessibilityLabel(text)
        button.isHidden = trailing != .add && trailing != .clear
        status.isHidden = trailing != .loading
        status.stringValue = String(localized: "Reading…")
        switch trailing {
        case .add:
            button.image = SidebarStyle.symbol("plus", size: 11)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = String(localized: "Add Folder to Favorites…")
            button.setAccessibilityLabel(String(localized: "Add Folder to Favorites"))
        case .clear:
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: String(localized: "Clear Recents"), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            button.toolTip = String(localized: "Clear Recent Files")
        default: break
        }
        button.onClick = action
    }
}

/// "↑ Documents › Notes": one button per path segment, the last one (the folder shown) in bold.
final class PathBarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("pathbar")
    private let bar = NSView()
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 6
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        for v in [bar, stack] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar)
        addSubview(stack)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override func viewDidChangeEffectiveAppearance() { bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }

    func configure(segments: [CurrentLocation.Segment], canGoUp: Bool, goUp: @escaping () -> Void, go: @escaping (URL) -> Void) {
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let up = ActionButton(symbol: "arrow.up", onClick: goUp)
        up.isEnabled = canGoUp
        up.toolTip = String(localized: "Parent Folder")
        up.setAccessibilityLabel(String(localized: "Parent Folder"))
        up.contentTintColor = canGoUp ? .secondaryLabelColor : .quaternaryLabelColor
        stack.addArrangedSubview(up)
        // lazy: only the last two segments are shown; the "…" stands for the rest and the ↑ button walks further up
        let shown = segments.suffix(2)
        if segments.count > 2 { stack.addArrangedSubview(Self.text("…", color: .tertiaryLabelColor)) }
        for (i, segment) in shown.enumerated() {
            let isLast = i == shown.count - 1
            let button = ActionButton(title: segment.title) { go(segment.url) }
            button.attributedTitle = NSAttributedString(string: segment.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isLast ? .semibold : .regular),
                .foregroundColor: isLast ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(isLast ? .defaultHigh : .defaultLow, for: .horizontal)
            button.toolTip = segment.url.path
            stack.addArrangedSubview(button)
            if !isLast { stack.addArrangedSubview(Self.text("›", color: .tertiaryLabelColor)) }
        }
        setAccessibilityLabel(String(localized: "Current location: \(segments.last?.title ?? "")"))
    }

    private static func text(_ s: String, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 11)
        f.textColor = color
        return f
    }
}

/// Empty-state sentence, "can't read this folder" hint, or skeleton bar.
final class NoticeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("notice")
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSView()
    private var indent: NSLayoutConstraint!
    private var barWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 3
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 4
        for v in [label, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        indent = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        barWidth = bar.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            indent,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: 24),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 9),
            barWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String?, depth: Int, skeletonIndex: Int?) {
        indent.constant = 14 + CGFloat(depth) * SidebarStyle.indent
        label.isHidden = text == nil
        label.stringValue = text ?? ""
        bar.isHidden = skeletonIndex == nil
        if let i = skeletonIndex {
            barWidth.constant = [110, 150, 90][i % 3]
            bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
        setAccessibilityElement(text != nil)
    }
}
