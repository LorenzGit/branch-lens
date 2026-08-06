import AppKit
import Foundation

/// Caches fully built highlighted attributed strings so Compare/Diff can switch
/// files without re-tokenizing or re-measuring on every visit.
enum HighlightRenderCache {
    struct Entry {
        let attributed: NSAttributedString
        let width: CGFloat
        let height: CGFloat
    }

    private static let lock = NSLock()
    private static var storage: [String: Entry] = [:]
    private static var lru: [String] = []
    private static let limit = 64
    private static let charWidth: CGFloat = {
        let sample = NSAttributedString(string: String(repeating: "M", count: 32), attributes: [
            .font: AppTheme.monoNS,
        ])
        return max(sample.size().width / 32, 7)
    }()

    static func key(
        kind: String,
        path: String,
        source: String,
        searchQuery: String,
        extra: String = ""
    ) -> String {
        // Length + ends + a cheap mid-content fingerprint (avoids hunk cache collisions).
        let prefix = source.prefix(96)
        let suffix = source.suffix(96)
        let fingerprint = fnv1a64(source)
        return "\(kind)|\(path)|\(source.count)|\(fingerprint)|\(prefix)|\(suffix)|\(searchQuery)|\(extra)"
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        // Sample the string so huge diffs stay cheap to key.
        let step = max(text.utf8.count / 4096, 1)
        var index = 0
        for byte in text.utf8 {
            if index % step == 0 {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            index += 1
        }
        hash ^= UInt64(text.utf8.count)
        hash &*= prime
        return hash
    }

    static func get(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        lru.append(key)
        return entry
    }

    static func set(_ key: String, entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = entry
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        lru.append(key)
        while storage.count > limit, let stale = lru.first {
            lru.removeFirst()
            storage.removeValue(forKey: stale)
        }
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
        lru.removeAll(keepingCapacity: true)
    }

    /// Fast mono-font width estimate — avoids full NSAttributedString.size() layout.
    static func estimateWidth(lineCharacterCounts maxChars: Int, padding: CGFloat) -> CGFloat {
        max(CGFloat(maxChars) * charWidth + padding, 400)
    }

    static func maxLineCharacterCount(in text: String) -> Int {
        var maxChars = 0
        var current = 0
        for ch in text {
            if ch == "\n" {
                maxChars = max(maxChars, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(maxChars, current)
    }
}
