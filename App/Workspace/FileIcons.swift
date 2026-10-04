import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// The icons Finder shows (list view, Open / Save panels): the system's own, so folders follow the folder colour, Desktop /
/// Documents / Downloads / the home folder have their glyphs, a folder or file with a custom icon shows it, and Markdown
/// files get the document icon of the app that opens them.
///
/// Nothing here may block the main thread, and a real icon can: the first lookup of one costs a few ms and drawing it up
/// to ~25 ms. So the main thread only ever reads the cache; a miss returns a placeholder at once (the generic folder or
/// document icon, or the file type's icon already cached) and queues the lookup on a utility queue, which draws the icon
/// into a 16 pt bitmap (2x) there and tells the rows with `didChange` when it has arrived.
///
/// What is looked up per path: folders (custom icons, special folders, iCloud Drive), files whose Finder flags say they
/// carry an icon of their own, and bundles. Every other file is looked up once per extension and shares that icon.
///
/// Cache: per path (NSCache, so memory pressure can empty it) and per extension, both per appearance (the icons have
/// light and dark variants). A path's icon is stamped with `FileIconStamps` and re-fetched when the folder watcher saw
/// its folder change; the old image stays on screen meanwhile.
final class FileIcons: @unchecked Sendable {
    static let shared = FileIcons()
    /// Posted on the main thread when icons arrived or went stale. `userInfo["path"]` is the one path concerned, absent for "all".
    static let didChange = Notification.Name("MacDown2.FileIcons.didChange")
    /// Icon size in points; rows are 24 pt high.
    static let size: CGFloat = 16

    private final class Entry: @unchecked Sendable {
        let image: NSImage?
        let stamp: FileIconStamps.Stamp
        init(image: NSImage?, stamp: FileIconStamps.Stamp) {
            self.image = image
            self.stamp = stamp
        }
    }

    private let lock = NSLock()
    private var stamps = FileIconStamps()
    /// "<ext>|<d or l>"; "#folder" and "#file" are the placeholders. An icon is reused for lookups only in the generation it was
    /// made in (`invalidateAll`: the default app for a type may have changed); older ones still serve as placeholders.
    private var byExtension: [String: (image: NSImage, generation: Int)] = [:]
    private let byPath = NSCache<NSString, Entry>()
    private var inFlight = Set<String>()
    private var warmed = Set<Bool>()  // the appearances whose placeholders were asked for
    private let queue = DispatchQueue(label: "MacDown2.FileIcons", qos: .utility)

    init() { byPath.countLimit = 4000 }

    // MARK: Main-thread side

    /// The icon to show now; nil only in the first milliseconds, before the placeholders exist (`didChange` follows).
    /// When it is not the real one yet, a lookup is queued and `didChange` is posted for `url` when it lands.
    func icon(for url: URL, isDirectory: Bool, dark: Bool) -> NSImage? {
        let path = url.path, key = path + (dark ? "|d" : "|l")
        lock.lock()
        let stamp = stamps.stamp(of: path)
        let entry = byPath.object(forKey: key as NSString)
        let image: NSImage?
        if let entry {
            image = entry.image
        } else if isDirectory {
            image = byExtension[Self.typeKey("#folder", dark)]?.image
        } else {
            image = (byExtension[Self.typeKey(url.pathExtension.lowercased(), dark)] ?? byExtension[Self.typeKey("#file", dark)])?.image
        }
        let needsFetch = entry?.stamp != stamp && inFlight.insert(key).inserted
        let needsWarm = warmed.insert(dark).inserted
        lock.unlock()
        if needsWarm { warm(dark: dark) }
        if needsFetch { fetch(path: path, key: key, isDirectory: isDirectory, dark: dark, stamp: stamp) }
        return image
    }

    /// Directories whose listing changed: the icons of what is in them (and of themselves) are looked up again.
    func invalidate(directories: [URL]) {
        lock.lock()
        stamps.invalidate(directories: directories.map(\.path))
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func invalidateAll() {
        lock.lock()
        stamps.invalidateAll()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func typeKey(_ ext: String, _ dark: Bool) -> String { ext + (dark ? "|d" : "|l") }

    // MARK: Background side

    private func warm(dark: Bool) {
        queue.async { [self] in
            Self.draw(dark: dark) {
                let folder = Self.bitmap(NSWorkspace.shared.icon(for: .folder)), file = Self.bitmap(NSWorkspace.shared.icon(for: .data))
                lock.lock()
                let generation = stamps.generation
                if let folder { byExtension[Self.typeKey("#folder", dark)] = (folder, generation) }
                if let file { byExtension[Self.typeKey("#file", dark)] = (file, generation) }
                lock.unlock()
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    // lazy: one serial queue, so a fast scrollbar drag through thousands of distinct folders queues lookups for rows already gone; upgrade: drop requests nobody asks for any more, or run a few lookups concurrently
    private func fetch(path: String, key: String, isDirectory: Bool, dark: Bool, stamp: FileIconStamps.Stamp) {
        queue.async { [self] in
            var image: NSImage?
            Self.draw(dark: dark) {
                let ext = (path as NSString).pathExtension.lowercased()
                if isDirectory || ext.isEmpty || FinderInfo.hasCustomIcon(atPath: path) || Self.isBundle(ext: ext) {
                    image = Self.bitmap(NSWorkspace.shared.icon(forFile: path))
                } else {
                    let typeKey = Self.typeKey(ext, dark)
                    lock.lock()
                    if let cached = byExtension[typeKey], cached.generation == stamp.generation { image = cached.image }
                    lock.unlock()
                    if image == nil {
                        image = Self.bitmap(NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
                        lock.lock()
                        if let image, stamps.isCurrent(stamp) { byExtension[typeKey] = (image, stamp.generation) }
                        lock.unlock()
                    }
                }
            }
            let result = Entry(image: image, stamp: stamp)
            DispatchQueue.main.async { [self] in
                lock.lock()
                if stamps.isCurrent(stamp) { byPath.setObject(result, forKey: key as NSString) }  // else: asked before an invalidateAll, ask again
                inFlight.remove(key)
                lock.unlock()
                NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["path": path])
            }
        }
    }

    private static func isBundle(ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .bundle) || type.conforms(to: .package)
    }

    private static func draw(dark: Bool, _ work: () -> Void) {
        if let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) { appearance.performAsCurrentDrawingAppearance(work) } else { work() }
    }

    /// The icon drawn into a bitmap of 2x the display size. NSWorkspace icons draw lazily, at the first `draw`, which would
    /// otherwise happen on the main thread inside the table's drawing pass.
    // lazy: always 2x (a 1x display scales it down, which is still sharp); upgrade: the screen's backingScaleFactor
    private static func bitmap(_ source: NSImage) -> NSImage? {
        let points = size, pixels = Int(size * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context  // pixel coordinates: the rep's size is set only after drawing
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: points, height: points)
        let image = NSImage(size: NSSize(width: points, height: points))
        image.addRepresentation(rep)
        return image
    }
}

extension NSView {
    var prefersDarkIcons: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A Finder icon in SwiftUI (the search results).
struct FileIconView: View {
    let url: URL
    var isDirectory = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSImage())
            .resizable()
            .frame(width: FileIcons.size, height: FileIcons.size)
            .accessibilityHidden(true)
            .onAppear(perform: load)
            .onChange(of: url) { load() }
            .onChange(of: colorScheme) { load() }
            .onReceive(NotificationCenter.default.publisher(for: FileIcons.didChange)) { note in
                if let path = note.userInfo?["path"] as? String, path != url.path { return }
                load()
            }
    }

    private func load() { image = FileIcons.shared.icon(for: url, isDirectory: isDirectory, dark: colorScheme == .dark) }
}
