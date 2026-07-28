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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text("#\(pr.number)")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())

                    Text(pr.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    if pr.isDraft {
                        Text("Draft")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.subtleFill, in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(pr.authorLogin)
                        .font(.caption.weight(.medium))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(pr.headRefName) → \(pr.baseRefName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }

                HStack {
                    Text(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        onOpen()
                    } label: {
                        Image(systemName: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open PR #\(pr.number) in browser")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : AppTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Inspect PR #\(pr.number): \(pr.headRefName) → \(pr.baseRefName)")
        .contextMenu {
            Button("Open in Browser") { onOpen() }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
        }
    }
}
