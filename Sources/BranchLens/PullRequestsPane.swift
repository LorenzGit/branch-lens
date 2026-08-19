import AppKit
import BranchLensCore
import SwiftUI

struct PullRequestsPane: View {
    @ObservedObject var model: RepoSession

    var body: some View {
        PanelChrome(fill: AppTheme.historyPanel) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.45)

                if model.isLoadingPullRequests && model.pullRequests.isEmpty {
                    ProgressView("Loading pull requests…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.pullRequestError, model.pullRequests.isEmpty {
                    ContentUnavailableView(
                        "Pull requests unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.pullRequests.isEmpty {
                    ContentUnavailableView(
                        "No \(model.pullRequestFilter.label.lowercased()) PRs",
                        systemImage: "arrow.triangle.pull",
                        description: Text("Nothing matched this filter.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.filteredPullRequests.isEmpty {
                    ContentUnavailableView(
                        "No matching authors",
                        systemImage: "person.2",
                        description: Text("No \(model.pullRequestFilter.label.lowercased()) PRs from the selected authors.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.filteredPullRequests) { pr in
                                PullRequestCard(
                                    pr: pr,
                                    isSelected: model.selectedPullRequestID == pr.number,
                                    onSelect: { model.selectPullRequest(pr) },
                                    onOpen: { model.openPullRequestInBrowser(pr) }
                                )
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            if model.pullRequests.isEmpty && model.pullRequestError == nil {
                Task { await model.loadPullRequests() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pull requests")
                    .font(.headline)
                Spacer()
                authorFilterMenu
                Button {
                    Task { await model.loadPullRequests() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoadingPullRequests)
                .help("Reload pull requests")
            }

            Picker("State", selection: Binding(
                get: { model.pullRequestFilter },
                set: { model.setPullRequestFilter($0) }
            )) {
                ForEach(PullRequestState.allCases) { state in
                    Text(state.label).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Filter by open or closed pull requests")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var authorFilterMenu: some View {
        Menu {
            Button("All authors") {
                model.clearPullRequestAuthorFilter()
            }
            if !model.pullRequestAuthors.isEmpty {
                Divider()
                ForEach(model.pullRequestAuthors, id: \.self) { author in
                    Button {
                        model.togglePullRequestAuthor(author)
                    } label: {
                        if model.selectedPullRequestAuthors.contains(author) {
                            Label(author, systemImage: "checkmark")
                        } else {
                            Text(author)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                Text(model.selectedPullRequestAuthors.isEmpty ? "Authors" : "\(model.selectedPullRequestAuthors.count)")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.subtleFill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.pullRequestAuthors.isEmpty)
        .help(model.selectedPullRequestAuthors.isEmpty
              ? "Filter pull requests by author"
              : "Filtering by \(model.selectedPullRequestAuthors.count) author\(model.selectedPullRequestAuthors.count == 1 ? "" : "s")")
    }
}

private struct PullRequestCard: View {
    let pr: PullRequestSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                Text(pr.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(pr.authorLogin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(pr.headRefName)
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    Text(pr.baseRefName)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .help("\(pr.headRefName) into \(pr.baseRefName)")

                HStack(spacing: 6) {
                    Text(pr.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let files = pr.changedFiles {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(files)f")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let additions = pr.additions {
                        Text("+\(additions)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.additionText)
                    }
                    if let deletions = pr.deletions {
                        Text("−\(deletions)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.deletionText)
                    }
                    Spacer(minLength: 0)
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.pull")
                                .font(.caption2.weight(.bold))
                            Text(pr.badgeLabel)
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(pr.badgeLabel) in the browser")
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.05),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("\(pr.badgeLabel): \(pr.headRefName) → \(pr.baseRefName)")
        .contextMenu {
            Button("Open \(pr.badgeLabel)") { onOpen() }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
        }
    }

    private var badgeColor: Color {
        switch pr.status {
        case "open":
            return pr.isDraft ? .secondary : AppTheme.additionText
        case "merged":
            return Color(red: 0.55, green: 0.40, blue: 0.90)
        default:
            return .secondary
        }
    }
}
