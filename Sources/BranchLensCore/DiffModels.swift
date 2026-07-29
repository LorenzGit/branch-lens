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
