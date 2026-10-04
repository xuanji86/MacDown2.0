import Foundation

/// What the file on disk holds, as far as "did it change" is concerned: its size and a 64-bit FNV-1a of its bytes.
public struct FileFingerprint: Equatable, Sendable {
    public let size: Int
    let hash: UInt64

    public init(_ data: Data) {
        size = data.count
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        hash = h
    }
}

/// The decision logic of "the file changed behind the editor's back" (PLAN I-1), free of UI and file system so it can be
/// tested exhaustively. File events are only hints: the caller reads the disk, hands the result to `probe`, and does what
/// comes back. The tracker remembers what the text in memory was last read from or written to (`synced`), so
/// - our own save is not a change (the save calls `didSync`, whatever the events say),
/// - a `touch`, or a rewrite with the same bytes, is not a change,
/// - a burst of writes is one change (the first probe that sees the new bytes decides; once the caller has re-read the file
///   and called `didSync`, the rest of the burst sees nothing new),
/// - however the file got there (in-place write, atomic rename-replace, delete and recreate) only the bytes count.
public struct ExternalChangeTracker: Equatable, Sendable {
    public enum Disk: Equatable, Sendable {
        case missing
        case present(FileFingerprint)
    }

    public enum Action: Equatable, Sendable {
        case none
        /// No unsaved changes: read the file again and call `didSync` with what was read.
        case reload
        /// Unsaved changes and a different file on disk: ask. Answer with `keepMine()` or, after reloading, `didSync`.
        case prompt
        /// The file is gone (deleted, or moved away): keep the text, show that a save is needed to bring it back.
        case markMissing
    }

    /// What the in-memory text corresponds to on disk; nil until the first read or probe.
    public private(set) var synced: Disk?
    /// The file was gone at the last probe (and nothing has been read or saved since).
    public private(set) var isMissing = false
    /// A prompt is open (at most one per document). More changes while it is open only change what a reload would load.
    public private(set) var isPrompting = false

    public init(synced: Disk? = nil) { self.synced = synced }

    /// The document just read this state from disk, or wrote it there (a save). Closes an open prompt: its question
    /// no longer applies.
    public mutating func didSync(_ disk: Disk) {
        synced = disk
        isMissing = disk == .missing
        isPrompting = false
    }

    /// The user kept their text over the file that is on disk now: that file is acknowledged, not asked about again.
    public mutating func keepMine(acknowledging disk: Disk) {
        guard isPrompting else { return }
        synced = disk
        isMissing = false
        isPrompting = false
    }

    /// The prompt could not be shown (no window): forget it, the next change asks again.
    public mutating func promptNotShown() { isPrompting = false }

    /// The file was read (`disk`); `isDirty` = the user has unsaved edits (not merely a marker for a missing file).
    public mutating func probe(_ disk: Disk, isDirty: Bool) -> Action {
        guard let known = synced else {
            synced = disk
            isMissing = disk == .missing
            return .none
        }
        if isPrompting {
            switch disk {
            case .missing:
                // The question is moot, the file is gone: keep the text, like any deletion.
                isPrompting = false
                isMissing = true
                return .markMissing
            case .present where disk == known:
                isPrompting = false  // changed back to what we have: nothing left to ask
                return .none
            case .present:
                return .none  // `Reload` reads the file when it is chosen, so it picks this change up as well
            }
        }
        switch disk {
        case .missing:
            guard !isMissing, known != .missing else { return .none }
            isMissing = true
            return .markMissing
        case .present:
            if disk == known {
                // Back with the very bytes we had (atomic replace with the same text, a restore): nothing to load, but
                // the file exists again, so only the marker goes.
                guard isMissing else { return .none }
                if isDirty { isMissing = false; return .none }
                return .reload
            }
            if isDirty {
                isPrompting = true
                return .prompt
            }
            return .reload
        }
    }
}
