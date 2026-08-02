import AppKit
import SwiftUI

/// Plain monospace editor with AppKit undo/redo (⌘Z / ⌘⇧Z).
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
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

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
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.string = text
        textView.delegate = context.coordinator

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.observeUndoManager(textView.undoManager)
        context.coordinator.publishUndoState()

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
            context.coordinator.publishUndoState()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onUndoStateChange: (Bool, Bool) -> Void
        weak var textView: NSTextView?
        var isUpdatingFromUI = false
        private var undoObservers: [NSObjectProtocol] = []

        init(text: Binding<String>, onUndoStateChange: @escaping (Bool, Bool) -> Void) {
            self.text = text
            self.onUndoStateChange = onUndoStateChange
        }

        deinit {
            for observer in undoObservers {
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

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isUpdatingFromUI = true
            text.wrappedValue = textView.string
            isUpdatingFromUI = false
            publishUndoState()
        }

        func publishUndoState() {
            let undoManager = textView?.undoManager
            onUndoStateChange(undoManager?.canUndo ?? false, undoManager?.canRedo ?? false)
        }

        func undo() {
            textView?.undoManager?.undo()
            publishUndoState()
        }

        func redo() {
            textView?.undoManager?.redo()
            publishUndoState()
        }
    }
}

/// Code-pane chrome wrapping `EditableSourceView`.
struct EditableCodePane: View {
    let title: String
    let subtitle: String
    let accent: Color
    @Binding var text: String
    var onUndoStateChange: (Bool, Bool) -> Void = { _, _ in }

    private var lineCount: Int {
        if text.isEmpty { return 0 }
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? max(count - 1, 1) : count
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
