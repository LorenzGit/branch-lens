import AppKit
import BranchLensCore
import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = WorkspaceModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.06),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabBarView(workspace: workspace)

                if let session = workspace.activeSession {
                    SessionContainer(session: session, workspace: workspace)
                        .id(session.id)
                } else {
                    EmptyWorkspaceView(workspace: workspace)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .task {
            await workspace.restoreIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive || phase == .background {
                workspace.saveNow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRepository)) { _ in
            workspace.openRepositoryPicker()
        }
        .confirmationDialog(
            "Close this tab?",
            isPresented: Binding(
                get: { workspace.tabPendingClose != nil },
                set: { if !$0 { workspace.cancelClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Tab", role: .destructive) {
                workspace.confirmClose()
            }
            Button("Cancel", role: .cancel) {
                workspace.cancelClose()
            }
        } message: {
            if let tab = workspace.tabPendingClose {
                Text("Close “\(workspace.title(for: tab))”?")
            }
        }
    }
}

private struct SessionContainer: View {
    @ObservedObject var session: RepoSession
    @ObservedObject var workspace: WorkspaceModel
    @FocusState private var focusedSearch: SearchFocusTarget?

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(model: session)
            if session.repoPath == nil {
                ProgressView("Opening repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.errorMessage, session.snapshot == nil {
                ErrorStateView(message: error) {
                    Task { await session.reloadSnapshot() }
                }
            } else {
                BranchWorkspaceView(
                    model: session,
                    workspace: workspace,
                    focusedSearch: $focusedSearch
                )
            }
        }
        .background {
            Button("Find") {
                session.activateFindShortcut()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: session.searchFocusNonce) { _, _ in
            focusedSearch = session.searchFocusTarget
        }
        .onChange(of: session.showHistory) { _, _ in session.onStateChange?() }
        .onChange(of: session.showFiles) { _, _ in session.onStateChange?() }
        .onChange(of: session.filesLayout) { _, _ in session.onStateChange?() }
        .onChange(of: session.fileViewMode) { _, _ in session.onStateChange?() }
        .onChange(of: session.fileNameQuery) { _, _ in session.onStateChange?() }
    }
}

// MARK: - Tab bar

private struct TabBarView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        TabChip(
                            session: tab,
                            workspace: workspace,
                            isActive: tab.id == workspace.activeSession?.id,
                            onSelect: { workspace.selectTab(tab.id) },
                            onClose: { workspace.requestClose(tab) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Menu {
                Button("Open Repository…") {
                    workspace.openRepositoryPicker()
                }
                .help("Open a local git repository in a new tab")
                if !workspace.recentRepos.isEmpty {
                    Divider()
                    Section("Recent") {
                        ForEach(workspace.recentRepos, id: \.path) { url in
                            Button(url.path) {
                                Task { await workspace.openRepository(at: url) }
                            }
                            .help(url.path)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("New tab — open a repository")
            .padding(.trailing, 8)
        }
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct TabChip: View {
    @ObservedObject var session: RepoSession
    @ObservedObject var workspace: WorkspaceModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var title: String {
        workspace.title(for: session)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(title)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help(session.repoPath?.path ?? "Switch to \(title)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close “\(title)”")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Toolbar

private struct ToolbarView: View {
    @ObservedObject var model: RepoSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if model.repoPath != nil {
                    BranchMenu(
                        title: "Branch",
                        icon: "arrow.triangle.branch",
                        value: model.selectedBranch,
                        options: model.branches,
                        emphasized: true,
                        helpText: "Branch to inspect"
                    ) { model.selectBranch($0) }

                    CompareBranchControl(model: model)

                    if let snapshot = model.snapshot {
                        CompactStats(model: model, snapshot: snapshot)
                    }

                    Spacer(minLength: 8)

                    if let status = model.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    columnToggles

                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoading || model.isUpdatingFromCompare)
                    .help("Fetch remotes and reload this branch")
                } else {
                    Spacer()
                }

                if model.isLoading || model.isUpdatingFromCompare {
                    ProgressView()
                        .controlSize(.small)
                        .help(model.isUpdatingFromCompare ? "Updating branch…" : "Loading…")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var columnToggles: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $model.showHistory) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help(model.showHistory ? "Hide History column" : "Show History column")

            Toggle(isOn: $model.showFiles) {
                Image(systemName: "list.bullet.indent")
            }
            .toggleStyle(.button)
            .help(model.showFiles ? "Hide Changed files column" : "Show Changed files column")
        }
    }
}

private struct CompactStats: View {
    @ObservedObject var model: RepoSession
    let snapshot: BranchSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text("\(snapshot.commits.count)c")
                .help("\(snapshot.commits.count) commits")
            Text("\(model.visibleFiles.count)f")
                .help("\(model.visibleFiles.count) files")
            HStack(spacing: 3) {
                Text("+\(model.visibleAdditions)")
                    .foregroundStyle(AppTheme.additionText)
                Text("−\(model.visibleDeletions)")
                    .foregroundStyle(AppTheme.deletionText)
            }
            .help("Lines added / deleted")
            Text(snapshot.mergeBaseShort)
                .foregroundStyle(.secondary)
                .help("Merge base with Compare branch \(snapshot.baseBranch)")
            if let tracking = snapshot.remoteTrackingBranch {
                let ahead = snapshot.aheadOfRemote ?? 0
                let behind = snapshot.behindRemote ?? 0
                Text("↑\(ahead)↓\(behind)")
                    .foregroundStyle(.secondary)
                    .help(tracking)
            } else {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.tertiary)
                    .help("No upstream")
            }
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.subtleFill, in: Capsule())
        .lineLimit(1)
    }
}

private struct CompareBranchControl: View {
    @ObservedObject var model: RepoSession

    private var compareAhead: Int {
        model.snapshot?.compareAheadCount ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            BranchMenu(
                title: "Compare",
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                value: model.baseBranch,
                options: model.branches,
                emphasized: false,
                badge: compareAhead > 0 ? "↑\(compareAhead)" : nil,
                badgeHelp: compareAhead > 0
                    ? "\(model.baseBranch) is \(compareAhead) commit\(compareAhead == 1 ? "" : "s") ahead of \(model.selectedBranch)"
                    : nil,
                helpText: "Branch to compare against (merge-base)"
            ) { model.selectBaseBranch($0) }

            if compareAhead > 0 {
                Button {
                    Task { await model.updateFromCompare() }
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isLoading || model.isUpdatingFromCompare || model.selectedBranch == model.baseBranch)
                .help("Merge latest from \(model.baseBranch) into \(model.selectedBranch) (\(compareAhead) commit\(compareAhead == 1 ? "" : "s"))")
            }
        }
    }
}

private struct BranchMenu: View {
    let title: String
    let icon: String
    let value: String
    let options: [String]
    let emphasized: Bool
    var badge: String? = nil
    var badgeHelp: String? = nil
    var helpText: String = ""
    let onSelect: (String) -> Void

    @State private var isOpen = false
    @State private var query = ""

    private var filteredOptions: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Button {
            query = ""
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(emphasized ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(value.isEmpty ? "Select…" : value)
                            .font(emphasized ? .callout.weight(.semibold) : .caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let badge {
                            Text(badge)
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.orange)
                                .help(badgeHelp ?? badge)
                        }
                    }
                }
                .frame(minWidth: emphasized ? 160 : 90, maxWidth: emphasized ? 280 : 180, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(emphasized ? Color.accentColor.opacity(0.10) : AppTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(emphasized ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText.isEmpty ? value : "\(helpText)\n\(value)")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            branchPickerPopover
        }
    }

    private var branchPickerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search branches…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if filteredOptions.isEmpty {
                Text(options.isEmpty ? "No branches" : "No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredOptions, id: \.self) { branch in
                            Button {
                                onSelect(branch)
                                isOpen = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: branch == value ? "checkmark" : "arrow.triangle.branch")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(branch == value ? Color.accentColor : .secondary)
                                        .frame(width: 14)
                                    Text(branch)
                                        .font(.callout.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(branch == value ? Color.accentColor.opacity(0.14) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Select \(branch)")
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .frame(width: 300)
    }
}

// MARK: - Empty / Error

private struct EmptyWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 108, height: 108)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 8) {
                Text("BranchLens")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Open a repository tab to inspect a branch — commits, files, Diff, Before, and After.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 12) {
                Button("Open Repository…") {
                    workspace.openRepositoryPicker()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command])
                .help("Open a local git repository (⌘O)")

                if !workspace.recentRepos.isEmpty {
                    Menu("Recent") {
                        ForEach(workspace.recentRepos, id: \.path) { url in
                            Button(url.path) {
                                Task { await workspace.openRepository(at: url) }
                            }
                            .help(url.path)
                        }
                    }
                    .controlSize(.large)
                    .help("Open a recently used repository")
                }
            }

            if !workspace.recentRepos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(workspace.recentRepos, id: \.path) { url in
                        Button {
                            Task { await workspace.openRepository(at: url) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(url.path)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Workspace

private struct BranchWorkspaceView: View {
    @ObservedObject var model: RepoSession
    @ObservedObject var workspace: WorkspaceModel
    var focusedSearch: FocusState<SearchFocusTarget?>.Binding
    /// Local widths avoid publishing every drag pixel (which makes resize feel jerky).
    @State private var historyWidth: CGFloat = 270
    @State private var filesWidth: CGFloat = 340

    var body: some View {
        HStack(spacing: 0) {
            if model.showHistory {
                CommitsPane(model: model)
                    .frame(width: historyWidth)
                    .frame(maxHeight: .infinity)
                ColumnResizeHandle(width: $historyWidth, range: 200...480) {
                    workspace.historyWidth = historyWidth
                    workspace.scheduleSave()
                }
            }

            if model.showFiles {
                FilesPane(model: model, focusedSearch: focusedSearch)
                    .frame(width: filesWidth)
                    .frame(maxHeight: .infinity)
                ColumnResizeHandle(width: $filesWidth, range: 240...560) {
                    workspace.filesWidth = filesWidth
                    workspace.scheduleSave()
                }
            }

            FileInspectorView(model: model, focusedSearch: focusedSearch)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .onAppear {
            historyWidth = workspace.historyWidth
            filesWidth = workspace.filesWidth
        }
        .onChange(of: workspace.historyWidth) { _, value in
            if abs(value - historyWidth) > 0.5 {
                historyWidth = value
            }
        }
        .onChange(of: workspace.filesWidth) { _, value in
            if abs(value - filesWidth) > 0.5 {
                filesWidth = value
            }
        }
    }
}

private struct ColumnResizeHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let onEnded: () -> Void
    @State private var startWidth: CGFloat?
    @State private var startX: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .help("Drag to resize column")
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if startWidth == nil {
                        startWidth = width
                        startX = value.startLocation.x
                    }
                    guard let startWidth, let startX else { return }
                    let delta = value.location.x - startX
                    let next = min(max(startWidth + delta, range.lowerBound), range.upperBound)
                    if abs(next - width) >= 0.5 {
                        width = next
                    }
                }
                .onEnded { _ in
                    startWidth = nil
                    startX = nil
                    onEnded()
                }
        )
    }
}

// MARK: - Commits

private struct CommitsPane: View {
    @ObservedObject var model: RepoSession

    var body: some View {
        PanelChrome(fill: AppTheme.historyPanel) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("History")
                        .font(.headline)
                    Spacer()
                    authorFilterMenu
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().opacity(0.45)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        if model.filteredCommits.count > 1 {
                            CombinedCommitCard(
                                isSelected: model.changeScope == .combined,
                                commitCount: model.filteredCommits.count,
                                fileCount: model.changeScope == .combined ? model.visibleFiles.count : (model.snapshot?.files.count ?? 0),
                                additions: model.snapshot?.totalAdditions ?? 0,
                                deletions: model.snapshot?.totalDeletions ?? 0
                            ) {
                                model.selectCombined()
                            }
                        }

                        if model.filteredCommits.isEmpty {
                            Text(model.selectedAuthors.isEmpty ? "No commits on this branch." : "No commits from selected authors.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        } else {
                            ForEach(model.filteredCommits) { commit in
                                CommitCard(
                                    commit: commit,
                                    isSelected: {
                                        if case .commit(let hash) = model.changeScope {
                                            return hash == commit.hash
                                        }
                                        // With a single commit, combined scope is the same change set.
                                        return model.changeScope == .combined && model.filteredCommits.count == 1
                                    }()
                                ) {
                                    model.selectCommit(commit)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var authorFilterMenu: some View {
        Menu {
            Button("All authors") {
                model.clearAuthorFilter()
            }
            if !model.branchAuthors.isEmpty {
                Divider()
                ForEach(model.branchAuthors, id: \.self) { author in
                    Button {
                        model.toggleAuthor(author)
                    } label: {
                        if model.selectedAuthors.contains(author) {
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
                Text(model.selectedAuthors.isEmpty ? "Authors" : "\(model.selectedAuthors.count)")
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
        .help(model.selectedAuthors.isEmpty
              ? "Filter commits by author"
              : "Filtering by \(model.selectedAuthors.count) author\(model.selectedAuthors.count == 1 ? "" : "s")")
    }
}

private struct CombinedCommitCard: View {
    let isSelected: Bool
    let commitCount: Int
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("All commits as one")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                Text("Review the whole branch as a single change set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("\(commitCount) commits")
                    Text("·")
                    Text("\(fileCount) files")
                    Spacer()
                    Text("+\(additions)")
                        .foregroundStyle(AppTheme.additionText)
                    Text("−\(deletions)")
                        .foregroundStyle(AppTheme.deletionText)
                }
                .font(.caption.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : AppTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("Show all \(commitCount) commits as one change set")
    }
}

private struct CommitCard: View {
    let commit: GitCommit
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Text(commit.subject)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(commit.shortHash)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Text(commit.authorName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(commit.authoredDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.05), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(commit.shortHash): \(commit.subject)")
    }
}

// MARK: - Files

private struct FilesPane: View {
    @ObservedObject var model: RepoSession
    var focusedSearch: FocusState<SearchFocusTarget?>.Binding
    @State private var expandedFolderIDs: Set<FileTreeNode.ID> = []

    var body: some View {
        PanelChrome {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Changed files")
                            .font(.headline)
                        Spacer()
                        Picker("Layout", selection: $model.filesLayout) {
                            ForEach(FilesLayoutMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 150)
                        .help(model.filesLayout == .folders
                              ? "Folder tree layout (switch to Flat)"
                              : "Flat list layout (switch to Folders)")
                    }

                    if !model.repoDirectoryPath.isEmpty {
                        Text(model.repoDirectoryPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(model.repoDirectoryPath)
                    }

                    Text(model.scopeCommitSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(model.activeScopeCommit?.subject ?? model.scopeCommitSummary)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter files…", text: $model.fileNameQuery)
                            .textFieldStyle(.plain)
                            .focused(focusedSearch, equals: .fileFilter)
                            .help("Filter changed files by name (⌘F when this column is active)")
                            .onTapGesture { model.preferFileSearch() }
                        if !model.fileNameQuery.isEmpty {
                            Button {
                                model.fileNameQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear file filter")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("Filter changed files by name")
                    .onTapGesture { model.preferFileSearch() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { model.preferFileSearch() }

                Divider().opacity(0.45)

                if model.filteredFiles.isEmpty {
                    ContentUnavailableView(
                        model.visibleFiles.isEmpty ? "No file changes" : "No matching files",
                        systemImage: "folder",
                        description: Text(model.visibleFiles.isEmpty ? "Nothing changed in this scope." : "Try a different file name filter.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.filesLayout == .flat {
                    flatList
                } else {
                    folderList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: model.filesLayout) { _, layout in
            if layout == .folders {
                expandAllFolders()
            }
        }
        .onChange(of: model.fileTree) { _, _ in
            if model.filesLayout == .folders {
                expandAllFolders()
            }
        }
        .onAppear {
            if model.filesLayout == .folders {
                expandAllFolders()
            }
        }
    }

    private var flatList: some View {
        List(selection: fileSelection) {
            ForEach(model.filteredFiles) { file in
                FileRow(file: file, showDirectory: true)
                    .tag(file.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.preferFileSearch() }
        .simultaneousGesture(TapGesture().onEnded { model.preferFileSearch() })
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.fileTree) { node in
                    FolderTreeRow(
                        node: node,
                        depth: 0,
                        selectedFileID: model.selectedFileID,
                        expandedFolderIDs: $expandedFolderIDs,
                        onSelect: { file in
                            model.preferFileSearch()
                            model.selectFile(file)
                        }
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.preferFileSearch() })
    }

    private var fileSelection: Binding<String?> {
        Binding(
            get: { model.selectedFileID },
            set: { newValue in
                if let id = newValue,
                   let file = model.visibleFiles.first(where: { $0.id == id }) {
                    model.preferFileSearch()
                    model.selectFile(file)
                } else {
                    model.selectedFileID = newValue
                }
            }
        )
    }

    private func expandAllFolders() {
        expandedFolderIDs = Set(collectFolderIDs(model.fileTree))
    }

    private func collectFolderIDs(_ nodes: [FileTreeNode]) -> [FileTreeNode.ID] {
        nodes.flatMap { node -> [FileTreeNode.ID] in
            guard node.isFolder else { return [] }
            return [node.id] + collectFolderIDs(node.children)
        }
    }
}

private struct FolderTreeRow: View {
    /// One indent step = folder icon width (keeps the tree tight and aligned).
    private static let iconWidth: CGFloat = 16

    let node: FileTreeNode
    let depth: Int
    let selectedFileID: String?
    @Binding var expandedFolderIDs: Set<FileTreeNode.ID>
    let onSelect: (ChangedFile) -> Void

    private var isExpanded: Bool {
        expandedFolderIDs.contains(node.id)
    }

    var body: some View {
        if let file = node.file {
            Button {
                onSelect(file)
            } label: {
                FileRow(file: file, showDirectory: false)
                    .padding(.leading, CGFloat(depth) * Self.iconWidth + Self.iconWidth)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedFileID == file.id ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(file.path)
            .contextMenu {
                Button("Copy File Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if isExpanded {
                        expandedFolderIDs.remove(node.id)
                    } else {
                        expandedFolderIDs.insert(node.id)
                    }
                } label: {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: CGFloat(depth) * Self.iconWidth)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.iconWidth, height: Self.iconWidth)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))

                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.iconWidth, height: Self.iconWidth)

                        Text(node.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 4)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse \(node.name)" : "Expand \(node.name)")

                if isExpanded {
                    ForEach(node.children) { child in
                        FolderTreeRow(
                            node: child,
                            depth: depth + 1,
                            selectedFileID: selectedFileID,
                            expandedFolderIDs: $expandedFolderIDs,
                            onSelect: onSelect
                        )
                    }
                }
            }
        }
    }
}

private struct FileRow: View {
    let file: ChangedFile
    var showDirectory: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Text(file.status.rawValue)
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)
                .background(statusColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showDirectory {
                    Text(directory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .foregroundStyle(AppTheme.additionText)
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)")
                        .foregroundStyle(AppTheme.deletionText)
                }
            }
            .font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy File Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }

    private var fileName: String {
        (file.path as NSString).lastPathComponent
    }

    private var directory: String {
        let dir = (file.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? file.path : dir
    }

    private var statusColor: Color {
        switch file.status {
        case .added: return AppTheme.additionText
        case .deleted: return AppTheme.deletionText
        case .renamed, .copied: return .purple
        default: return .orange
        }
    }
}

// MARK: - Inspector

private struct FileInspectorView: View {
    @ObservedObject var model: RepoSession
    var focusedSearch: FocusState<SearchFocusTarget?>.Binding

    var body: some View {
        PanelChrome {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.45)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.preferContentSearch() })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let file = model.selectedFile {
                HStack(spacing: 10) {
                    Text(file.status.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusBackground(for: file), in: Capsule())
                    Text(file.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if model.isLoadingFile {
                        ProgressView().controlSize(.small)
                    }
                    Text(CodeHighlighter.fileExtension(of: file.path).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.subtleFill, in: Capsule())
                }
            } else {
                Text("Inspector")
                    .font(.headline)
            }

            HStack(spacing: 10) {
                Picker(selection: $model.fileViewMode) {
                    ForEach(FileViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .help("View mode: Diff, Before, After, or side-by-side Compare")

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search in view…", text: $model.contentQuery)
                        .textFieldStyle(.plain)
                        .focused(focusedSearch, equals: .content)
                        .frame(minWidth: 140, maxWidth: 220)
                        .help("Search in the current file view (⌘F)")
                        .onTapGesture { model.preferContentSearch() }
                    if !model.contentQuery.isEmpty {
                        Text("\(model.contentMatchCount)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .help("\(model.contentMatchCount) match\(model.contentMatchCount == 1 ? "" : "es")")
                        Button {
                            model.contentQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear content search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Search in the current file view")
                .onTapGesture { model.preferContentSearch() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingFile && model.fileDiff.isEmpty && model.beforeContents == nil {
            ProgressView("Loading file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedFile == nil {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a changed file to inspect Diff, Before, or After.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.fileViewMode {
            case .diff:
                DiffScrollView(
                    text: model.fileDiff,
                    path: model.selectedFile?.path ?? "file.txt",
                    searchQuery: model.contentQuery
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .before:
                CodePane(
                    title: "Before",
                    subtitle: model.beforeLabel,
                    accent: AppTheme.deletionText,
                    source: model.beforeContents,
                    path: model.selectedFile?.oldPath ?? model.selectedFile?.path ?? "file.txt",
                    placeholder: "File did not exist in this revision.",
                    lineCount: model.beforeLineCount,
                    searchQuery: model.contentQuery
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .after:
                CodePane(
                    title: "After",
                    subtitle: model.afterLabel,
                    accent: AppTheme.additionText,
                    source: model.afterContents,
                    path: model.selectedFile?.path ?? "file.txt",
                    placeholder: "File does not exist in this revision.",
                    lineCount: model.afterLineCount,
                    searchQuery: model.contentQuery
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .compare:
                HStack(spacing: 10) {
                    CodePane(
                        title: "Before",
                        subtitle: model.beforeLabel,
                        accent: AppTheme.deletionText,
                        source: model.beforeContents,
                        path: model.selectedFile?.oldPath ?? model.selectedFile?.path ?? "file.txt",
                        placeholder: "File did not exist in this revision.",
                        lineCount: model.beforeLineCount,
                        searchQuery: model.contentQuery
                    )
                    CodePane(
                        title: "After",
                        subtitle: model.afterLabel,
                        accent: AppTheme.additionText,
                        source: model.afterContents,
                        path: model.selectedFile?.path ?? "file.txt",
                        placeholder: "File does not exist in this revision.",
                        lineCount: model.afterLineCount,
                        searchQuery: model.contentQuery
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func statusBackground(for file: ChangedFile) -> Color {
        switch file.status {
        case .added: return AppTheme.additionFill
        case .deleted: return AppTheme.deletionFill
        case .renamed, .copied: return .purple.opacity(0.18)
        default: return .orange.opacity(0.18)
        }
    }
}

private struct PanelChrome<Content: View>: View {
    var fill: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                Group {
                    if let fill {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(fill)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.regularMaterial)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

#Preview {
    ContentView()
}
