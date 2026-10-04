import Foundation

/// Paper size, orientation and margins of a PDF export or a printout (Settings > Export), as plain values. Points
/// (1/72 in) throughout; the Settings page shows them in the user's units. The app turns this into an `NSPrintInfo`
/// (PrintKit); `macdown2 render --export pdf` reads the same keys from the app's preferences.
public struct PageSetup: Equatable, Sendable {
    public enum Paper: String, CaseIterable, Sendable {
        case letter, legal, a3, a4, a5

        /// Portrait size in points.
        public var size: (width: Double, height: Double) {
            switch self {
            case .letter: (612, 792)
            case .legal: (612, 1008)
            case .a3: (841.89, 1190.55)
            case .a4: (595.28, 841.89)
            case .a5: (419.53, 595.28)
            }
        }

        public var title: String {
            switch self {
            case .letter: "US Letter"
            case .legal: "US Legal"
            case .a3: "A3"
            case .a4: "A4"
            case .a5: "A5"
            }
        }

        /// What a Mac in this region has in its printer: Letter in North America and the Philippines, A4 everywhere else.
        public static func standard(for locale: Locale = .current) -> Paper {
            switch locale.region?.identifier {
            case "US", "CA", "MX", "PR", "PH": .letter
            default: .a4
            }
        }
    }

    public enum Orientation: String, CaseIterable, Sendable { case portrait, landscape }

    /// 3/4 in: what the print path used before it was a setting.
    public static let defaultMargin = 54.0
    /// 0 to 2 in. Anything outside is clamped, so a typo cannot leave no room for text.
    public static let marginRange = 0.0...144.0

    public var paper: Paper
    public var orientation: Orientation = .portrait
    public var top = PageSetup.defaultMargin
    public var right = PageSetup.defaultMargin
    public var bottom = PageSetup.defaultMargin
    public var left = PageSetup.defaultMargin

    public init(locale: Locale = .current) {
        paper = .standard(for: locale)
    }

    /// The sheet as it comes out of the printer: width x height in points, orientation applied.
    public var pageSize: (width: Double, height: Double) {
        let size = paper.size
        return orientation == .portrait ? size : (size.height, size.width)
    }

    // MARK: Persistence

    public enum Key {
        public static let paper = "export.paper"
        public static let orientation = "export.orientation"
        public static let top = "export.margin.top"
        public static let right = "export.margin.right"
        public static let bottom = "export.margin.bottom"
        public static let left = "export.margin.left"
    }

    /// A key that is absent or holds the wrong type reads as the default.
    public init(defaults: UserDefaults, locale: Locale = .current) {
        self.init(locale: locale)
        if let raw = defaults.string(forKey: Key.paper), let value = Paper(rawValue: raw) { paper = value }
        if let raw = defaults.string(forKey: Key.orientation), let value = Orientation(rawValue: raw) { orientation = value }
        func margin(_ key: String, _ value: inout Double) {
            if let number = defaults.object(forKey: key) as? Double, number.isFinite { value = number.clamped(to: Self.marginRange) }
        }
        margin(Key.top, &top)
        margin(Key.right, &right)
        margin(Key.bottom, &bottom)
        margin(Key.left, &left)
    }

    /// Only values that differ from the default are stored (a default that changes later, like the paper for a new region,
    /// then still reaches users who never touched it).
    public func write(to defaults: UserDefaults, locale: Locale = .current) {
        let standard = PageSetup(locale: locale)
        func store<T: Equatable>(_ key: String, _ value: T, _ initial: T, as encode: (T) -> Any) {
            if value == initial { defaults.removeObject(forKey: key) } else { defaults.set(encode(value), forKey: key) }
        }
        store(Key.paper, paper, standard.paper) { $0.rawValue }
        store(Key.orientation, orientation, standard.orientation) { $0.rawValue }
        store(Key.top, top.clamped(to: Self.marginRange), standard.top) { $0 }
        store(Key.right, right.clamped(to: Self.marginRange), standard.right) { $0 }
        store(Key.bottom, bottom.clamped(to: Self.marginRange), standard.bottom) { $0 }
        store(Key.left, left.clamped(to: Self.marginRange), standard.left) { $0 }
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
