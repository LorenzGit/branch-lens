import AppKit
import Foundation

public enum TokenKind: Sendable {
    case plain
    case keyword
    case string
    case comment
    case number
}

public struct HighlightToken: Sendable {
    public let text: String
    public let kind: TokenKind
}

public enum CodeHighlighter {
    struct LanguageSpec {
        var keywords: Set<String>
        var lineComment: String?
        var blockComment: (String, String)?
    }

    public static func fileExtension(of path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    public static func tokenize(_ source: String, path: String) -> [HighlightToken] {
        tokenize(source, fileExtension: fileExtension(of: path))
    }

    public static func tokenize(_ source: String, fileExtension ext: String) -> [HighlightToken] {
        let spec = spec(forExtension: ext)
        var tokens: [HighlightToken] = []
        let chars = Array(source)
        var i = 0
        let n = chars.count

        func startsWith(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard index + t.count <= n else { return false }
            for (offset, ch) in t.enumerated() where chars[index + offset] != ch { return false }
            return true
        }

        while i < n {
            let ch = chars[i]

            if let (open, close) = spec.blockComment, startsWith(open, at: i) {
                var j = i
                while j < n, !startsWith(close, at: j) { j += 1 }
                let end = min(n, j + close.count)
                tokens.append(HighlightToken(text: String(chars[i..<end]), kind: .comment))
                i = end
                continue
            }

            if let lc = spec.lineComment, startsWith(lc, at: i) {
                var j = i
                while j < n, chars[j] != "\n" { j += 1 }
                tokens.append(HighlightToken(text: String(chars[i..<j]), kind: .comment))
                i = j
                continue
            }

            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch
                var j = i + 1
                while j < n {
                    if chars[j] == "\\", j + 1 < n {
                        j += 2
                        continue
                    }
                    if chars[j] == quote || chars[j] == "\n" { break }
                    j += 1
                }
                if j < n, chars[j] == quote { j += 1 }
                tokens.append(HighlightToken(text: String(chars[i..<j]), kind: .string))
                i = j
                continue
            }

            if ch.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < n, chars[j].isHexDigit || "xXoObB._eE+-".contains(chars[j]) {
                    if "+-".contains(chars[j]), j > i, !"eE".contains(chars[j - 1]) { break }
                    j += 1
                }
                tokens.append(HighlightToken(text: String(chars[i..<j]), kind: .number))
                i = j
                continue
            }

            if ch.isLetter || ch == "_" {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    j += 1
                }
                let word = String(chars[i..<j])
                tokens.append(HighlightToken(
                    text: word,
                    kind: spec.keywords.contains(word) ? .keyword : .plain
                ))
                i = j
                continue
            }

            tokens.append(HighlightToken(text: String(ch), kind: .plain))
            i += 1
        }

        return tokens
    }

    public static func attributedString(
        _ source: String,
        path: String,
        plainColor: NSColor,
        keywordColor: NSColor,
        stringColor: NSColor,
        commentColor: NSColor,
        numberColor: NSColor,
        font: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: plainColor,
        ]
        for token in tokenize(source, path: path) {
            var attrs = base
            switch token.kind {
            case .plain: break
            case .keyword: attrs[.foregroundColor] = keywordColor
            case .string: attrs[.foregroundColor] = stringColor
            case .comment: attrs[.foregroundColor] = commentColor
            case .number: attrs[.foregroundColor] = numberColor
            }
            result.append(NSAttributedString(string: token.text, attributes: attrs))
        }
        return result
    }

    static func spec(forExtension ext: String) -> LanguageSpec {
        switch ext {
        case "swift":
            return LanguageSpec(keywords: [
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init",
                "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open",
                "operator", "override", "private", "protocol", "public", "repeat", "required", "rethrows",
                "return", "self", "Self", "static", "struct", "subscript", "super", "switch", "throw",
                "throws", "true", "try", "typealias", "var", "weak", "where", "while", "some", "any",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "js", "mjs", "cjs", "ts", "tsx", "jsx":
            return LanguageSpec(keywords: [
                "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false",
                "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof",
                "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
                "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "py":
            return LanguageSpec(keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
                "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
                "True", "try", "while", "with", "yield", "match", "case", "self",
            ], lineComment: "#", blockComment: nil)
        case "go":
            return LanguageSpec(keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil",
                "package", "range", "return", "select", "struct", "switch", "true", "type", "var",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "rs":
            return LanguageSpec(keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "true", "type", "unsafe", "use", "where", "while",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm", "java", "kt", "kts", "cs", "scala":
            return LanguageSpec(keywords: [
                "abstract", "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue",
                "default", "delete", "do", "double", "else", "enum", "extern", "false", "final", "finally",
                "float", "for", "goto", "if", "import", "include", "inline", "int", "interface", "long",
                "namespace", "new", "nil", "null", "nullptr", "override", "package", "private", "protected",
                "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template",
                "this", "throw", "throws", "true", "try", "typedef", "union", "unsigned", "using",
                "val", "var", "virtual", "void", "volatile", "while", "fun", "when", "object",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "rb":
            return LanguageSpec(keywords: [
                "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end",
                "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "raise",
                "redo", "require", "rescue", "retry", "return", "self", "super", "then", "true",
                "undef", "unless", "until", "when", "while", "yield",
            ], lineComment: "#", blockComment: nil)
        case "sh", "bash", "zsh", "fish":
            return LanguageSpec(keywords: [
                "case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for", "function",
                "if", "in", "local", "read", "return", "then", "until", "while", "echo", "set", "source",
            ], lineComment: "#", blockComment: nil)
        case "css", "scss", "less":
            return LanguageSpec(keywords: [
                "important", "from", "to", "and", "or", "not", "only",
            ], lineComment: nil, blockComment: ("/*", "*/"))
        case "html", "htm", "xml", "svg":
            return LanguageSpec(keywords: [], lineComment: nil, blockComment: ("<!--", "-->"))
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties":
            return LanguageSpec(keywords: ["true", "false", "null", "yes", "no"], lineComment: "#", blockComment: nil)
        case "sql":
            return LanguageSpec(keywords: [
                "select", "from", "where", "insert", "into", "values", "update", "delete", "create",
                "table", "index", "join", "left", "right", "inner", "outer", "on", "group", "by",
                "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "primary",
                "key", "foreign", "references", "distinct", "union", "all", "exists", "between", "like",
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "CREATE",
                "TABLE", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY",
                "ORDER", "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "PRIMARY",
                "KEY", "FOREIGN", "REFERENCES", "DISTINCT", "UNION", "ALL", "EXISTS", "BETWEEN", "LIKE",
            ], lineComment: "--", blockComment: ("/*", "*/"))
        case "json", "jsonc":
            return LanguageSpec(keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil)
        case "md", "markdown":
            return LanguageSpec(keywords: [], lineComment: nil, blockComment: nil)
        case "php":
            return LanguageSpec(keywords: [
                "abstract", "array", "as", "break", "case", "catch", "class", "const", "continue",
                "declare", "default", "do", "echo", "else", "elseif", "extends", "false", "final",
                "finally", "for", "foreach", "function", "if", "implements", "include", "interface",
                "namespace", "new", "null", "print", "private", "protected", "public", "require",
                "return", "static", "switch", "throw", "trait", "true", "try", "use", "var", "while",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        default:
            return LanguageSpec(keywords: [], lineComment: nil, blockComment: nil)
        }
    }
}
