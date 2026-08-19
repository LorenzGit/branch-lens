import BranchLensCore
import SwiftUI

/// Diff viewer split into per-hunk cards. Optional Stage / Unstage actions for local scopes.
struct HunkDiffView: View, Equatable {
    let text: String
    let path: String
    let searchQuery: String
    var actionTitle: String? = nil
    var onHunkAction: ((DiffHunk) -> Void)? = nil

    static func == (lhs: HunkDiffView, rhs: HunkDiffView) -> Bool {
        lhs.text == rhs.text
            && lhs.path == rhs.path
            && lhs.searchQuery == rhs.searchQuery
            && lhs.actionTitle == rhs.actionTitle
            && (lhs.onHunkAction == nil) == (rhs.onHunkAction == nil)
    }

    /// Prefer a single scrollable diff when the hunk UI would create too many NSTextViews
    /// (common for large PR / All-changes files and a frequent hang source).
    private static let maxHunkCardsForReview = 28
    private static let maxDiffLinesForReviewCards = 2_000
    /// Hunks taller than this get an internal scroller instead of expanding the outer stack.
    private static let maxHunkBodyLinesExpanded = 140

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || text.hasPrefix("(No textual diff") {
            ContentUnavailableView(
                "No textual diff",
                systemImage: "doc.plaintext",
                description: Text(
                    onHunkAction == nil
                        ? "Binary or empty change."
                        : "Binary or empty change. Use Stage File / Unstage File from the file list."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let hunks = DiffParser.hunks(in: text)
            let lineCount = Self.newlineCount(in: text)
            let needsActions = onHunkAction != nil
            let useCards = !hunks.isEmpty && (
                needsActions
                || (hunks.count <= Self.maxHunkCardsForReview
                    && lineCount <= Self.maxDiffLinesForReviewCards)
            )

            if useCards {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(hunks) { hunk in
                            HunkCard(
                                hunk: hunk,
                                path: path,
                                searchQuery: searchQuery,
                                actionTitle: actionTitle,
                                expandBodyLines: Self.maxHunkBodyLinesExpanded,
                                onAction: onHunkAction.map { action in
                                    { action(hunk) }
                                }
                            )
                            // Stable identity — avoids remount/highlight storms while scrolling.
                            .id(hunk.id)
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Review-only large diffs: one DiffScrollView is far cheaper than N fitted cards.
                DiffScrollView(text: text, path: path, searchQuery: searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private static func newlineCount(in text: String) -> Int {
        if text.isEmpty { return 0 }
        var count = 1
        for byte in text.utf8 where byte == 10 {
            count += 1
        }
        return count
    }
}

private struct HunkCard: View {
    let hunk: DiffHunk
    let path: String
    let searchQuery: String
    let actionTitle: String?
    let expandBodyLines: Int
    let onAction: (() -> Void)?

    private var bodyLineCount: Int { max(hunk.body.count, 1) }
    private var usesInnerScroll: Bool { bodyLineCount > expandBodyLines }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(AppTheme.hunkText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if hunk.changeCount > 0 {
                    Text("\(hunk.changeCount)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if let onAction, let actionTitle {
                    if hunk.isSyntheticUntracked {
                        Button("Stage File") { onAction() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Untracked file — stage the whole file")
                    } else {
                        Button(actionTitle) { onAction() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("\(actionTitle) this hunk")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.hunkFill)

            DiffScrollView(
                text: hunkDisplayText,
                path: path,
                searchQuery: searchQuery,
                allowsScrolling: usesInnerScroll,
                omitHunkHeaders: true
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(maxHeight: usesInnerScroll ? 320 : nil)
            .fixedSize(horizontal: false, vertical: !usesInnerScroll)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// Include the `@@` header so DiffScrollView can recover before/after line numbers;
    /// the header itself is omitted from the rendered body (shown in card chrome).
    private var hunkDisplayText: String {
        ([hunk.header] + hunk.body.map(\.raw)).joined(separator: "\n")
    }
}
