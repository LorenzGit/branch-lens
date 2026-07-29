import BranchLensCore
import SwiftUI

/// Diff viewer with per-hunk Stage / Unstage actions for local working-tree scopes.
struct HunkDiffView: View {
    let text: String
    let path: String
    let searchQuery: String
    let actionTitle: String
    let onHunkAction: (DiffHunk) -> Void

    private var hunks: [DiffHunk] {
        DiffParser.hunks(in: text)
    }

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || text.hasPrefix("(No textual diff") {
            ContentUnavailableView(
                "No textual diff",
                systemImage: "doc.plaintext",
                description: Text("Binary or empty change. Use Stage File / Unstage File from the file list.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hunks.isEmpty {
            DiffScrollView(text: text, path: path, searchQuery: searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(hunks) { hunk in
                        HunkCard(
                            hunk: hunk,
                            path: path,
                            searchQuery: searchQuery,
                            actionTitle: actionTitle,
                            onAction: { onHunkAction(hunk) }
                        )
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HunkCard: View {
    let hunk: DiffHunk
    let path: String
    let searchQuery: String
    let actionTitle: String
    let onAction: () -> Void

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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.hunkFill)

            DiffScrollView(
                text: hunkDisplayText,
                path: path,
                searchQuery: searchQuery,
                allowsScrolling: false
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// Body only — the `@@` header is already shown in the card chrome.
    private var hunkDisplayText: String {
        hunk.body.map(\.raw).joined(separator: "\n")
    }
}
