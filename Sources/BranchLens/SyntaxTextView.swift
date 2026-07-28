import AppKit
import BranchLensCore
import SwiftUI

enum SearchHighlight {
    static let color = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.20, alpha: 0.55)

    static func apply(to attributed: NSMutableAttributedString, query: String) -> NSRange? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let full = attributed.string as NSString
        var searchRange = NSRange(location: 0, length: full.length)
        var first: NSRange?
        while searchRange.length > 0 {
            let found = full.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            if found.location == NSNotFound { break }
            attributed.addAttribute(.backgroundColor, value: color, range: found)
            if first == nil { first = found }
            let next = found.location + max(found.length, 1)
            if next >= full.length { break }
            searchRange = NSRange(location: next, length: full.length - next)
        }
        return first
    }

    static func scroll(textView: NSTextView, to range: NSRange?) {
        guard let range, range.location != NSNotFound else { return }
        textView.scrollRangeToVisible(range)
    }
}

/// Non-wrapping, selectable, syntax-highlighted source viewer.
struct SyntaxTextView: NSViewRepresentable {
    let source: String
    let path: String
    var showLineNumbers: Bool = true
    var searchQuery: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 4
        textView.font = AppTheme.monoNS
        textView.allowsUndo = false

        scroll.documentView = textView
        context.coordinator.textView = textView
        apply(to: textView)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else { return }
        let key = "\(path)||\(source.count)||\(source.hashValue)||\(showLineNumbers)||\(searchQuery)"
        guard context.coordinator.renderedKey != key else { return }
        context.coordinator.renderedKey = key
        apply(to: textView)
    }

    private func apply(to textView: NSTextView) {
        let attributed = NSMutableAttributedString(attributedString: buildAttributed())
        let first = SearchHighlight.apply(to: attributed, query: searchQuery)
        textView.textStorage?.setAttributedString(attributed)
        textView.backgroundColor = .textBackgroundColor
        let width = max(attributed.size().width + 40, 400)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        textView.sizeToFit()
        SearchHighlight.scroll(textView: textView, to: first)
    }

    private func buildAttributed() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let gutterWidth = showLineNumbers ? max(3, String(lines.count).count) : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.alignment = .left

        for (index, line) in lines.enumerated() {
            if showLineNumbers {
                let gutter = String(format: "%\(gutterWidth)d  ", index + 1)
                result.append(NSAttributedString(string: gutter, attributes: [
                    .font: AppTheme.monoNS,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph,
                ]))
            }

            let highlighted = CodeHighlighter.attributedString(
                String(line),
                path: path,
                plainColor: AppTheme.plainCode,
                keywordColor: AppTheme.keywordCode,
                stringColor: AppTheme.stringCode,
                commentColor: AppTheme.commentCode,
                numberColor: AppTheme.numberCode,
                font: AppTheme.monoNS
            )
            let mutable = NSMutableAttributedString(attributedString: highlighted)
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))
            result.append(mutable)

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: AppTheme.monoNS,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return result
    }

    final class Coordinator {
        var textView: NSTextView?
        var renderedKey: String?
    }
}

/// Diff view with green/red rows and syntax-colored code; never wraps characters.
struct DiffScrollView: NSViewRepresentable {
    let text: String
    let path: String
    var searchQuery: String = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = AppTheme.monoNS

        scroll.documentView = textView
        context.coordinator.textView = textView
        apply(to: textView)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else { return }
        let key = "\(path)||\(text.hashValue)||\(searchQuery)"
        guard context.coordinator.renderedKey != key else { return }
        context.coordinator.renderedKey = key
        apply(to: textView)
    }

    private func apply(to textView: NSTextView) {
        let attributed = NSMutableAttributedString(attributedString: buildDiffAttributed())
        let first = SearchHighlight.apply(to: attributed, query: searchQuery)
        textView.textStorage?.setAttributedString(attributed)
        let width = max(attributed.size().width + 48, 480)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        textView.sizeToFit()
        SearchHighlight.scroll(textView: textView, to: first)
    }

    private func buildDiffAttributed() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = DiffParser.parse(text).filter { $0.kind != .meta && $0.kind != .header }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        for (index, line) in lines.enumerated() {
            let bg: NSColor
            switch line.kind {
            case .addition:
                bg = NSColor(calibratedRed: 0.18, green: 0.64, blue: 0.35, alpha: 0.22)
            case .deletion:
                bg = NSColor(calibratedRed: 0.86, green: 0.24, blue: 0.27, alpha: 0.22)
            case .hunk:
                bg = NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.95, alpha: 0.16)
            default:
                bg = .clear
            }

            let oldGutter = line.oldLine.map { String(format: "%4d", $0) } ?? "    "
            let newGutter = line.newLine.map { String(format: "%4d", $0) } ?? "    "
            let prefix: String
            switch line.kind {
            case .addition: prefix = "+"
            case .deletion: prefix = "−"
            case .context: prefix = " "
            default: prefix = " "
            }

            let gutterColor: NSColor = .secondaryLabelColor
            let prefixColor: NSColor = {
                switch line.kind {
                case .addition: return NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.45, alpha: 1)
                case .deletion: return NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.38, alpha: 1)
                default: return .secondaryLabelColor
                }
            }()

            let prefixAttrs: [NSAttributedString.Key: Any] = [
                .font: AppTheme.monoBoldNS,
                .foregroundColor: prefixColor,
                .backgroundColor: bg,
                .paragraphStyle: paragraph,
            ]
            let gutterAttrs: [NSAttributedString.Key: Any] = [
                .font: AppTheme.monoNS,
                .foregroundColor: gutterColor,
                .backgroundColor: bg,
                .paragraphStyle: paragraph,
            ]

            result.append(NSAttributedString(string: "\(oldGutter) \(newGutter) ", attributes: gutterAttrs))
            result.append(NSAttributedString(string: "\(prefix) ", attributes: prefixAttrs))

            switch line.kind {
            case .addition, .deletion, .context:
                let highlighted = CodeHighlighter.attributedString(
                    line.code,
                    path: path,
                    plainColor: AppTheme.plainCode,
                    keywordColor: AppTheme.keywordCode,
                    stringColor: AppTheme.stringCode,
                    commentColor: AppTheme.commentCode,
                    numberColor: AppTheme.numberCode,
                    font: AppTheme.monoNS
                )
                let mutable = NSMutableAttributedString(attributedString: highlighted)
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .backgroundColor: bg,
                    .paragraphStyle: paragraph,
                ]
                mutable.addAttributes(codeAttrs, range: NSRange(location: 0, length: mutable.length))
                result.append(mutable)
            case .hunk:
                result.append(NSAttributedString(string: line.raw, attributes: [
                    .font: AppTheme.monoBoldNS,
                    .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.70, blue: 1.0, alpha: 1),
                    .backgroundColor: bg,
                    .paragraphStyle: paragraph,
                ]))
            case .meta, .header:
                break
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: AppTheme.monoNS,
                    .backgroundColor: bg,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return result
    }

    final class Coordinator {
        var textView: NSTextView?
        var renderedKey: String?
    }
}
