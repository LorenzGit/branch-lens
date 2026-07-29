import Foundation

public enum DiffLineKind: Sendable, Hashable {
    case header
    case hunk
    case context
    case addition
    case deletion
    case meta
}

public struct DiffLine: Identifiable, Sendable, Hashable {
    public let id: Int
    public let kind: DiffLineKind
    public let raw: String
    public let code: String
    public let oldLine: Int?
    public let newLine: Int?

    public init(id: Int, kind: DiffLineKind, raw: String, code: String, oldLine: Int?, newLine: Int?) {
        self.id = id
        self.kind = kind
        self.raw = raw
        self.code = code
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let header: String
    public let body: [DiffLine]

    public init(id: Int, header: String, body: [DiffLine]) {
        self.id = id
        self.header = header
        self.body = body
    }

    public var isSyntheticUntracked: Bool {
        header.contains("untracked")
    }

    public var changeCount: Int {
        body.reduce(0) { count, line in
            switch line.kind {
            case .addition, .deletion: return count + 1
            default: return count
            }
        }
    }
}

public enum DiffParser {
    /// Old-file line numbers that were deleted, and new-file line numbers that were added.
    public static func changedLineNumbers(in text: String) -> (deleted: Set<Int>, added: Set<Int>) {
        var deleted = Set<Int>()
        var added = Set<Int>()
        for line in parse(text) {
            switch line.kind {
            case .deletion:
                if let old = line.oldLine { deleted.insert(old) }
            case .addition:
                if let new = line.newLine { added.insert(new) }
            default:
                break
            }
        }
        return (deleted, added)
    }

    /// Group parsed diff lines into hunks (header + body until the next hunk).
    public static func hunks(in text: String) -> [DiffHunk] {
        let lines = parse(text)
        var result: [DiffHunk] = []
        var currentHeader: String?
        var currentID = 0
        var body: [DiffLine] = []

        func flush() {
            guard let header = currentHeader else { return }
            result.append(DiffHunk(id: currentID, header: header, body: body))
            body = []
            currentHeader = nil
        }

        for line in lines {
            switch line.kind {
            case .hunk:
                flush()
                currentHeader = line.raw
                currentID = line.id
            case .addition, .deletion, .context:
                if currentHeader != nil {
                    body.append(line)
                }
            case .meta, .header:
                break
            }
        }
        flush()
        return result
    }

    /// Build a standalone unified patch for one hunk that `git apply --cached` can consume.
    public static func patch(
        for hunk: DiffHunk,
        path: String,
        oldPath: String? = nil,
        originalDiff: String
    ) -> String? {
        guard !hunk.isSyntheticUntracked else { return nil }
        guard hunk.header.hasPrefix("@@") else { return nil }

        let meta = parse(originalDiff).filter { $0.kind == .meta }.map(\.raw)
        let diffGit = meta.first(where: { $0.hasPrefix("diff --git ") })
            ?? "diff --git a/\(oldPath ?? path) b/\(path)"
        let oldHeader = meta.last(where: { $0.hasPrefix("--- ") })
            ?? "--- a/\(oldPath ?? path)"
        let newHeader = meta.last(where: { $0.hasPrefix("+++ ") })
            ?? "+++ b/\(path)"

        var lines = [diffGit, oldHeader, newHeader, hunk.header]
        lines.append(contentsOf: hunk.body.map(\.raw))
        // git apply is happier with a trailing newline.
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldLine: Int?
        var newLine: Int?
        var index = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            defer { index += 1 }

            if raw.hasPrefix("@@") {
                let nums = parseHunkHeader(raw)
                oldLine = nums.old
                newLine = nums.new
                lines.append(DiffLine(id: index, kind: .hunk, raw: raw, code: raw, oldLine: nil, newLine: nil))
                continue
            }

            if raw.hasPrefix("diff ") || raw.hasPrefix("index ") || raw.hasPrefix("---") || raw.hasPrefix("+++")
                || raw.hasPrefix("new file") || raw.hasPrefix("deleted file") || raw.hasPrefix("similarity")
                || raw.hasPrefix("rename ") || raw.hasPrefix("copy ") || raw.hasPrefix("Binary ") {
                lines.append(DiffLine(id: index, kind: .meta, raw: raw, code: raw, oldLine: nil, newLine: nil))
                continue
            }

            if raw.hasPrefix("+") {
                let code = String(raw.dropFirst())
                lines.append(DiffLine(id: index, kind: .addition, raw: raw, code: code, oldLine: nil, newLine: newLine))
                if let n = newLine { newLine = n + 1 }
                continue
            }

            if raw.hasPrefix("-") {
                let code = String(raw.dropFirst())
                lines.append(DiffLine(id: index, kind: .deletion, raw: raw, code: code, oldLine: oldLine, newLine: nil))
                if let o = oldLine { oldLine = o + 1 }
                continue
            }

            if raw.hasPrefix("\\") {
                lines.append(DiffLine(id: index, kind: .meta, raw: raw, code: raw, oldLine: nil, newLine: nil))
                continue
            }

            // Context line (leading space) or plain.
            let code = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
            lines.append(DiffLine(id: index, kind: .context, raw: raw, code: code, oldLine: oldLine, newLine: newLine))
            if let o = oldLine { oldLine = o + 1 }
            if let n = newLine { newLine = n + 1 }
        }

        return lines
    }

    private static func parseHunkHeader(_ line: String) -> (old: Int?, new: Int?) {
        // @@ -12,3 +14,7 @@
        guard let at = line.range(of: "@@") else { return (nil, nil) }
        let rest = line[at.upperBound...]
        guard let end = rest.range(of: "@@") else { return (nil, nil) }
        let body = rest[..<end.lowerBound]
        let parts = body.split(whereSeparator: \.isWhitespace)
        var old: Int?
        var new: Int?
        for part in parts {
            if part.hasPrefix("-") {
                old = Int(part.dropFirst().split(separator: ",").first ?? "")
            } else if part.hasPrefix("+") {
                new = Int(part.dropFirst().split(separator: ",").first ?? "")
            }
        }
        return (old, new)
    }
}
