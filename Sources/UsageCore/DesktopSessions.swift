import Foundation

/// What the Claude desktop app knows about its own sessions, read from the metadata it
/// writes beside them.
///
/// Two things the transcript alone cannot tell us:
///
/// - **The name the user sees.** A transcript records a renamed session in a
///   `custom-title` line, but in a long session that line sits far from the end and the
///   tail reader never reaches it, so the list fell back to the folder name.
/// - **Whether a transcript is still the session's own.** Clearing a session starts a
///   new transcript and points the metadata at it; the old file keeps its modification
///   time for a while and would otherwise linger in the list beside its replacement,
///   carrying the old compaction count.
///
/// Read-only, and only these four fields. The same metadata is mirrored into a second
/// profile directory, so entries are de-duplicated by session id, newest kept.
public struct DesktopMeta: Sendable, Equatable {
    public let title: String
    public let archived: Bool
    public let activeAt: Date
}

public final class DesktopSessions: @unchecked Sendable {
    private let roots: [String]
    /// file path → (mtime, session id, meta) so a rescan only re-reads what changed;
    /// there are hundreds of these files and parsing them all costs about three seconds.
    private var seen: [String: (mtime: Date, sid: String, meta: DesktopMeta)] = [:]
    private var byId: [String: DesktopMeta] = [:]
    public private(set) var loaded = false

    public init(home: String = Paths.home) {
        roots = ["Claude Second", "Claude"].map {
            home + "/Library/Application Support/\($0)/claude-code-sessions"
        }
    }

    public static func directories(home: String = Paths.home) -> [String] {
        DesktopSessions(home: home).roots
    }

    public func meta(_ sessionId: String) -> DesktopMeta? { byId[sessionId] }

    /// True once metadata has been found at all. Until then the caller must not treat a
    /// missing entry as "this session was replaced" — it may simply be unreadable here.
    public var usable: Bool { loaded && !byId.isEmpty }

    /// Value of a top-level key, read straight from the bytes. Enough for these four
    /// fields; anything more structured would mean decoding the whole file again.
    private static func value(_ data: Data, _ key: String) -> Data.SubSequence? {
        guard let r = data.range(of: Data("\"\(key)\":".utf8)) else { return nil }
        return data[r.upperBound...]
    }

    static func text(_ data: Data, _ key: String) -> String? {
        guard var rest = value(data, key), rest.first == 0x22 else { return nil }
        rest = rest.dropFirst()
        var out = [UInt8](), escaped = false
        for b in rest {
            if escaped { out.append(b == 0x6E ? 0x0A : b); escaped = false; continue }
            if b == 0x5C { escaped = true; continue }
            if b == 0x22 { break }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func flag(_ data: Data, _ key: String) -> Bool {
        guard let rest = value(data, key) else { return false }
        return rest.starts(with: Data("true".utf8))
    }

    static func number(_ data: Data, _ key: String) -> Double? {
        guard let rest = value(data, key) else { return nil }
        let digits = rest.prefix { (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D }
        return Double(String(decoding: digits, as: UTF8.self))
    }

    public func refresh() {
        let fm = FileManager.default
        var current: Set<String> = []
        for root in roots {
            guard let walker = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".json") {
                let path = root + "/" + rel
                guard (rel as NSString).lastPathComponent.hasPrefix("local_") else { continue }
                current.insert(path)
                let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                if let hit = seen[path], hit.mtime == mtime { continue }
                // These files run to half a megabyte each — most of it lists of enabled
                // tools — and there are hundreds. Decoding them all cost three seconds
                // and tens of megabytes, so the four fields are lifted out of the bytes
                // instead, and the file is released before the next one is opened.
                autoreleasepool {
                    // Mapped rather than copied: these are half a megabyte each and only
                    // a few dozen bytes of each are wanted, so the pages can be dropped
                    // again under pressure instead of sitting in the heap.
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                          let sid = Self.text(data, "cliSessionId"), !sid.isEmpty else { return }
                    let meta = DesktopMeta(
                        title: Self.text(data, "title") ?? "",
                        archived: Self.flag(data, "isArchived"),
                        activeAt: Date(timeIntervalSince1970: (Self.number(data, "lastActivityAt") ?? 0) / 1000))
                    seen[path] = (mtime ?? .distantPast, sid, meta)
                }
            }
        }
        seen = seen.filter { current.contains($0.key) }
        // One entry per session, keeping the profile that saw it most recently.
        var merged: [String: DesktopMeta] = [:]
        for (_, hit) in seen {
            if let prev = merged[hit.sid], prev.activeAt >= hit.meta.activeAt { continue }
            merged[hit.sid] = hit.meta
        }
        byId = merged
        loaded = true
    }
}
