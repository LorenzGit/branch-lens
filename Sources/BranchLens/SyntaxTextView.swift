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
        scheduleApply(to: textView, coordinator: context.coordinator, cacheKey: contentKey())
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else { return }
        let key = contentKey()
        guard context.coordinator.renderedKey != key else { return }
        scheduleApply(to: textView, coordinator: context.coordinator, cacheKey: key)
    }

    private func contentKey() -> String {
        HighlightRenderCache.key(
            kind: showLineNumbers ? "source" : "source-noln",
            path: path,
            source: source,
            searchQuery: searchQuery
        )
    }

    private func scheduleApply(to textView: NSTextView, coordinator: Coordinator, cacheKey: String? = nil) {
        let cacheKey = cacheKey ?? contentKey()
        coordinator.renderGeneration &+= 1
        let generation = coordinator.renderGeneration

        if let cached = HighlightRenderCache.get(cacheKey) {
            applyEntry(cached, to: textView, scrollToSearch: true)
            coordinator.renderedKey = cacheKey
            return
        }

        // Keep previous content visible while the next file highlights off-main.
        let source = self.source
        let path = self.path
        let showLineNumbers = self.showLineNumbers
        let searchQuery = self.searchQuery
        let colors = SyntaxRenderBuilder.Colors.current()
        let font = AppTheme.monoNS
        let lineHeight = font.ascender - font.descender + font.leading

        coordinator.renderTask?.cancel()
        coordinator.renderTask = Task.detached(priority: .userInitiated) {
            let attributed = NSMutableAttributedString(
                attributedString: SyntaxRenderBuilder.buildSource(
                    source: source,
                    path: path,
                    showLineNumbers: showLineNumbers,
                    font: font,
                    colors: colors
                )
            )
            _ = SearchHighlight.apply(to: attributed, query: searchQuery)
            let maxChars = HighlightRenderCache.maxLineCharacterCount(in: attributed.string)
            let width = HighlightRenderCache.estimateWidth(lineCharacterCounts: maxChars, padding: 40)
            let lineCount = source.isEmpty ? 1 : source.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let height = max(CGFloat(lineCount) * max(lineHeight, 14) + 24, 40)
            let entry = HighlightRenderCache.Entry(attributed: attributed, width: width, height: height)
            HighlightRenderCache.set(cacheKey, entry: entry)

            await MainActor.run {
                guard !Task.isCancelled, coordinator.renderGeneration == generation else { return }
                applyEntry(entry, to: textView, scrollToSearch: true)
                coordinator.renderedKey = cacheKey
            }
        }
    }

    private func applyEntry(_ entry: HighlightRenderCache.Entry, to textView: NSTextView, scrollToSearch: Bool) {
        textView.textStorage?.setAttributedString(entry.attributed)
        textView.backgroundColor = .textBackgroundColor
        // Restore cached metrics — skip sizeToFit (major Compare switch cost).
        textView.frame = NSRect(x: 0, y: 0, width: entry.width, height: entry.height)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if scrollToSearch, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let full = entry.attributed.string as NSString
            let found = full.range(of: searchQuery, options: [.caseInsensitive, .diacriticInsensitive])
            SearchHighlight.scroll(textView: textView, to: found.location == NSNotFound ? nil : found)
        }
    }

    final class Coordinator {
        var textView: NSTextView?
        var renderedKey: String?
        var renderGeneration: Int = 0
        var renderTask: Task<Void, Never>?
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
        scheduleApply(to: textView, coordinator: context.coordinator, cacheKey: contentKey())
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else { return }
        let key = contentKey()
        guard context.coordinator.renderedKey != key else { return }
        scheduleApply(to: textView, coordinator: context.coordinator, cacheKey: key)
    }

    private func contentKey() -> String {
        HighlightRenderCache.key(kind: "diff", path: path, source: text, searchQuery: searchQuery)
    }

    private func scheduleApply(to textView: NSTextView, coordinator: Coordinator, cacheKey: String? = nil) {
        let cacheKey = cacheKey ?? contentKey()
        coordinator.renderGeneration &+= 1
        let generation = coordinator.renderGeneration

        if let cached = HighlightRenderCache.get(cacheKey) {
            applyEntry(cached, to: textView)
            coordinator.renderedKey = cacheKey
            return
        }

        let text = self.text
        let path = self.path
        let searchQuery = self.searchQuery
        let colors = SyntaxRenderBuilder.Colors.current()
        let font = AppTheme.monoNS
        let boldFont = AppTheme.monoBoldNS
        let lineHeight = font.ascender - font.descender + font.leading

        coordinator.renderTask?.cancel()
        coordinator.renderTask = Task.detached(priority: .userInitiated) {
            let attributed = NSMutableAttributedString(
                attributedString: SyntaxRenderBuilder.buildDiff(
                    text: text,
                    path: path,
                    font: font,
                    boldFont: boldFont,
                    colors: colors
                )
            )
            _ = SearchHighlight.apply(to: attributed, query: searchQuery)
            let maxChars = HighlightRenderCache.maxLineCharacterCount(in: attributed.string)
            let width = HighlightRenderCache.estimateWidth(lineCharacterCounts: maxChars, padding: 48)
            let lineCount = text.isEmpty ? 1 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let height = max(CGFloat(lineCount) * max(lineHeight, 14) + 24, 40)
            let entry = HighlightRenderCache.Entry(attributed: attributed, width: width, height: height)
            HighlightRenderCache.set(cacheKey, entry: entry)

            await MainActor.run {
                guard !Task.isCancelled, coordinator.renderGeneration == generation else { return }
                applyEntry(entry, to: textView)
                coordinator.renderedKey = cacheKey
            }
        }
    }

    private func applyEntry(_ entry: HighlightRenderCache.Entry, to textView: NSTextView) {
        textView.textStorage?.setAttributedString(entry.attributed)
        textView.frame = NSRect(x: 0, y: 0, width: entry.width, height: entry.height)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let full = entry.attributed.string as NSString
            let found = full.range(of: searchQuery, options: [.caseInsensitive, .diacriticInsensitive])
            SearchHighlight.scroll(textView: textView, to: found.location == NSNotFound ? nil : found)
        }
    }

    final class Coordinator {
        var textView: NSTextView?
        var renderedKey: String?
        var renderGeneration: Int = 0
        var renderTask: Task<Void, Never>?
    }
}

/// Off-main-actor highlight builders (colors/fonts captured on the main thread first).
enum SyntaxRenderBuilder {
    struct Colors: @unchecked Sendable {
        let plain: NSColor
        let keyword: NSColor
        let string: NSColor
        let comment: NSColor
        let number: NSColor
        let gutter: NSColor
        let secondary: NSColor

        @MainActor
        static func current() -> Colors {
            Colors(
                plain: AppTheme.plainCode,
                keyword: AppTheme.keywordCode,
                string: AppTheme.stringCode,
                comment: AppTheme.commentCode,
                number: AppTheme.numberCode,
                gutter: .tertiaryLabelColor,
                secondary: .secondaryLabelColor
            )
        }
    }

    nonisolated static func buildSource(
        source: String,
        path: String,
        showLineNumbers: Bool,
        font: NSFont,
        colors: Colors
    ) -> NSAttributedString {
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
                    .font: font,
                    .foregroundColor: colors.gutter,
                    .paragraphStyle: paragraph,
                ]))
            }

            let highlighted = CodeHighlighter.attributedString(
                String(line),
                path: path,
                plainColor: colors.plain,
                keywordColor: colors.keyword,
                stringColor: colors.string,
                commentColor: colors.comment,
                numberColor: colors.number,
                font: font
            )
            let mutable = NSMutableAttributedString(attributedString: highlighted)
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))
            result.append(mutable)

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return result
    }

    nonisolated static func buildDiff(
        text: String,
        path: String,
        font: NSFont,
        boldFont: NSFont,
        colors: Colors
    ) -> NSAttributedString {
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

            let prefixColor: NSColor = {
                switch line.kind {
                case .addition: return NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.45, alpha: 1)
                case .deletion: return NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.38, alpha: 1)
                default: return colors.secondary
                }
            }()

            let prefixAttrs: [NSAttributedString.Key: Any] = [
                .font: boldFont,
                .foregroundColor: prefixColor,
                .backgroundColor: bg,
                .paragraphStyle: paragraph,
            ]
            let gutterAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colors.secondary,
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
                    plainColor: colors.plain,
                    keywordColor: colors.keyword,
                    stringColor: colors.string,
                    commentColor: colors.comment,
                    numberColor: colors.number,
                    font: font
                )
                let mutable = NSMutableAttributedString(attributedString: highlighted)
                mutable.addAttributes([
                    .backgroundColor: bg,
                    .paragraphStyle: paragraph,
                ], range: NSRange(location: 0, length: mutable.length))
                result.append(mutable)
            case .hunk:
                result.append(NSAttributedString(string: line.raw, attributes: [
                    .font: boldFont,
                    .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.70, blue: 1.0, alpha: 1),
                    .backgroundColor: bg,
                    .paragraphStyle: paragraph,
                ]))
            case .meta, .header:
                break
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .backgroundColor: bg,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return result
    }
}
