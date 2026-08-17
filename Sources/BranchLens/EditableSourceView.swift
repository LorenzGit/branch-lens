import AppKit
import SwiftUI

/// Plain monospace editor with AppKit undo/redo (⌘Z / ⌘⇧Z) and a line-number gutter.
struct EditableSourceView: NSViewRepresentable {
    @Binding var text: String
    var onUndoStateChange: (Bool, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUndoStateChange: onUndoStateChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.usesPredominantAxisScrolling = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 4
        textView.font = AppTheme.monoNS
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.string = text
        textView.delegate = context.coordinator
        textView.postsFrameChangedNotifications = true

        scroll.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scroll.verticalRulerView = ruler
        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler
        context.coordinator.observeUndoManager(textView.undoManager)
        context.coordinator.observeTextView(textView)
        context.coordinator.publishUndoState()
        ruler.rebuildLineStarts(for: textView.string)
        ruler.needsDisplay = true
        context.coordinator.sizeDocument(textView)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onUndoStateChange = onUndoStateChange
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else { return }
        if !context.coordinator.isUpdatingFromUI, textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let max = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, max), length: 0))
            context.coordinator.rulerView?.rebuildLineStarts(for: text)
            context.coordinator.sizeDocument(textView)
            context.coordinator.publishUndoState()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onUndoStateChange: (Bool, Bool) -> Void
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        var isUpdatingFromUI = false
        private var undoObservers: [NSObjectProtocol] = []
        private var viewObservers: [NSObjectProtocol] = []

        init(text: Binding<String>, onUndoStateChange: @escaping (Bool, Bool) -> Void) {
            self.text = text
            self.onUndoStateChange = onUndoStateChange
        }

        deinit {
            for observer in undoObservers + viewObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observeUndoManager(_ undoManager: UndoManager?) {
            for observer in undoObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            undoObservers.removeAll()
            guard let undoManager else { return }

            let names: [Notification.Name] = [
                .NSUndoManagerDidUndoChange,
                .NSUndoManagerDidRedoChange,
                .NSUndoManagerDidOpenUndoGroup,
                .NSUndoManagerDidCloseUndoGroup,
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(
                    forName: name,
                    object: undoManager,
                    queue: .main
                ) { [weak self] _ in
                    self?.publishUndoState()
                }
                undoObservers.append(token)
            }
        }

        func observeTextView(_ textView: NSTextView) {
            for observer in viewObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            viewObservers.removeAll()

            let frameToken = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                self?.rulerView?.needsDisplay = true
            }
            viewObservers.append(frameToken)

            if let scroll = textView.enclosingScrollView?.contentView {
                let boundsToken = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scroll,
                    queue: .main
                ) { [weak self] _ in
                    self?.rulerView?.needsDisplay = true
                }
                viewObservers.append(boundsToken)
                scroll.postsBoundsChangedNotifications = true
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isUpdatingFromUI = true
            text.wrappedValue = textView.string
            isUpdatingFromUI = false
            rulerView?.rebuildLineStarts(for: textView.string)
            sizeDocument(textView)
            publishUndoState()
        }

        func sizeDocument(_ textView: NSTextView) {
            let maxChars = HighlightRenderCache.maxLineCharacterCount(in: textView.string)
            let width = HighlightRenderCache.estimateWidth(lineCharacterCounts: maxChars, padding: 48)
            let font = textView.font ?? AppTheme.monoNS
            let lineHeight = max(font.ascender - font.descender + font.leading, 14)
            let lines = textView.string.isEmpty ? 1 : textView.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let height = max(CGFloat(lines) * lineHeight + 24, 40)
            let clip = textView.enclosingScrollView?.contentSize ?? .zero
            textView.minSize = NSSize(width: width, height: height)
            textView.frame.size = NSSize(width: max(width, clip.width), height: max(height, clip.height))
        }

        func publishUndoState() {
            let undoManager = textView?.undoManager
            onUndoStateChange(undoManager?.canUndo ?? false, undoManager?.canRedo ?? false)
        }
    }
}

/// Vertical gutter showing 1-based line numbers for an `NSTextView`.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Character offsets of each line start (including a trailing empty line after `\n`).
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func rebuildLineStarts(for text: String) {
        var starts: [Int] = [0]
        var index = 0
        for ch in text.utf16 {
            index += 1
            if ch == 10 { // \n
                starts.append(index)
            }
        }
        lineStarts = starts
        updateThickness()
        needsDisplay = true
    }

    /// Never call this from `drawHashMarksAndLabels` — changing thickness during draw can hang layout.
    private func updateThickness() {
        let digits = max(String(max(lineStarts.count, 1)).count, 2)
        let width = CGFloat(digits) * numberFont.maximumAdvancement.width + 16
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let scrollView = scrollView
        else { return }

        NSColor.textBackgroundColor.withAlphaComponent(0.92).setFill()
        rect.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        edge.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let relative = convert(NSPoint.zero, from: textView)
        let insetY = textView.textContainerInset.height
        let fontHeight = numberFont.boundingRectForFont.height

        if textView.string.isEmpty {
            drawNumber(1, atY: insetY, attributes: attrs)
            return
        }

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let nsString = textView.string as NSString
        var drawnLineStarts = Set<Int>()

        if glyphRange.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphs, _ in
                let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
                guard charRange.location != NSNotFound else { return }
                let lineStart = nsString.lineRange(for: NSRange(location: charRange.location, length: 0)).location
                guard drawnLineStarts.insert(lineStart).inserted else { return }
                let number = self.lineNumber(forCharacterLocation: lineStart)
                let y = relative.y + usedRect.minY + insetY + (usedRect.height - fontHeight) / 2
                self.drawNumber(number, atY: y, attributes: attrs)
            }
        }

        let extra = layoutManager.extraLineFragmentUsedRect
        if extra.height > 0, textView.string.hasSuffix("\n") {
            let number = lineStarts.count
            let y = relative.y + extra.minY + insetY + (extra.height - fontHeight) / 2
            drawNumber(number, atY: y, attributes: attrs)
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let string = "\(number)" as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: bounds.maxX - size.width - 6, y: y),
            withAttributes: attributes
        )
    }

    private func lineNumber(forCharacterLocation location: Int) -> Int {
        // Binary search into cached line starts — O(log n) instead of rescanning the file.
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let start = lineStarts[mid]
            let next = mid + 1 < lineStarts.count ? lineStarts[mid + 1] : Int.max
            if location < start {
                high = mid - 1
            } else if location >= next {
                low = mid + 1
            } else {
                return mid + 1
            }
        }
        return max(low, 1)
    }
}

/// Code-pane chrome wrapping `EditableSourceView`.
struct EditableCodePane: View {
    let title: String
    let subtitle: String
    let accent: Color
    @Binding var text: String
    var externallyChanged: Bool = false
    var onReloadFromDisk: (() -> Void)? = nil
    var onKeepEditing: (() -> Void)? = nil
    var onUndoStateChange: (Bool, Bool) -> Void = { _, _ in }

    private var lineCount: Int {
        if text.isEmpty { return 1 }
        return text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("Editing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                Text("\(lineCount) lines")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.subtleFill, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppTheme.subtleFill)

            if externallyChanged {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This file changed on disk.")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Button("Keep Editing") {
                        onKeepEditing?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Keep your buffer and ignore the external change")
                    Button("Reload") {
                        onReloadFromDisk?()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Replace the editor buffer with the file on disk")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            Divider().opacity(0.45)

            EditableSourceView(text: $text, onUndoStateChange: onUndoStateChange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.5)
        )
    }
}
