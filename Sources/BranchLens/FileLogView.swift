import BranchLensCore
import SwiftUI

struct FileLogView: View {
    @ObservedObject var model: RepoSession

    private var path: String {
        if case .fileLog(let path) = model.inspectorMode { return path }
        return ""
    }

    var body: some View {
        PanelChrome {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.45)
                if model.isLoadingFileLog && model.fileLogEntries.isEmpty {
                    ProgressView("Loading file history…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.fileLogError, model.fileLogEntries.isEmpty {
                    ContentUnavailableView(
                        "Couldn’t load log",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.fileLogEntries.isEmpty {
                    ContentUnavailableView(
                        "No history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("No commits touched this path.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        entryList
                            .frame(width: 320)
                        Divider()
                        diffPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.closeFileLog()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Return to file inspector")

            VStack(alignment: .leading, spacing: 2) {
                Text("Log")
                    .font(.headline)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }

            Spacer(minLength: 8)

            Text("\(model.fileLogEntries.count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.subtleFill, in: Capsule())
                .help("\(model.fileLogEntries.count) commits touching this file")

            if model.isLoadingFileLog || model.isLoadingFileLogDiff {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.fileLogEntries) { entry in
                    Button {
                        model.selectFileLogEntry(entry)
                    } label: {
                        FileLogEntryRow(
                            entry: entry,
                            isSelected: model.selectedFileLogID == entry.hash
                        )
                    }
                    .buttonStyle(.plain)
                    .help("\(entry.shortHash) · \(entry.authorName)")
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.historyPanel.opacity(0.55))
    }

    private var diffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = model.fileLogEntries.first(where: { $0.hash == model.selectedFileLogID }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.subject)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(entry.shortHash)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(entry.authorName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.authoredDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    if !entry.decorations.isEmpty {
                        Text(entry.decorations)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help("Refs pointing at this commit")
                    }
                    if !model.fileLogContainingBranches.isEmpty {
                        Text(model.fileLogContainingBranches.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help("Branches containing this commit")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider().opacity(0.45)
            }

            if model.isLoadingFileLogDiff && model.fileLogDiff.isEmpty {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffScrollView(text: model.fileLogDiff, path: path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct FileLogEntryRow: View {
    let entry: FileLogEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.subject)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(entry.shortHash)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(entry.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(entry.authoredDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !entry.decorations.isEmpty {
                    Text(entry.decorations)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.05),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }
}
