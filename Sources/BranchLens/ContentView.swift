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
            if phase == .active {
                Task { await workspace.refreshActiveTabIfNeeded() }
            } else if phase == .inactive || phase == .background {
                workspace.saveNow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // scenePhase can miss some macOS focus transitions; this backs it up.
            Task { await workspace.refreshActiveTabIfNeeded() }
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

            Button("Find in Files") {
                session.openCrossFileSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $session.isCrossFileSearchPresented) {
            CrossFileSearchSheet(model: session)
        }
        .sheet(isPresented: $session.isCommitSheetPresented) {
            CommitSheet(model: session)
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
                        tipDates: model.branchTipDates,
                        emphasized: true,
                        badge: upstreamBadge(for: model.snapshot),
                        badgeHelp: upstreamBadgeHelp(for: model.snapshot),
                        badgeStyle: upstreamBadgeStyle(for: model.snapshot),
                        helpText: "Branch to inspect"
                    ) { model.selectBranch($0) }

                    if model.unpushedCommitCount > 0 {
                        Button {
                            Task { await model.pushBranch() }
                        } label: {
                            if model.isPushing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("\(model.unpushedCommitCount) Push")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.additionText)
                        .controlSize(.small)
                        .disabled(model.isPushing || model.isLoading || model.isCommitting)
                        .help("Push \(model.unpushedCommitCount) unpushed commit\(model.unpushedCommitCount == 1 ? "" : "s") on \(model.selectedBranch)")
                    }

                    CompareBranchControl(model: model)

                    WorktreeMenu(model: model)

                    if let snapshot = model.snapshot {
                        CompactStats(model: model, snapshot: snapshot)
                            .layoutPriority(1)
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
                    .help("Fetch remotes and reload this branch (also resets the 3-minute auto-refresh cooldown)")
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
            Picker("Side pane", selection: Binding(
                get: { model.sidePaneMode },
                set: { model.setSidePaneMode($0) }
            )) {
                ForEach(SidePaneMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show commit History or Pull requests")

            Toggle(isOn: $model.showHistory) {
                Image(systemName: model.sidePaneMode == .pullRequests ? "arrow.triangle.pull" : "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help(model.showHistory
                  ? (model.sidePaneMode == .pullRequests ? "Hide Pull requests column" : "Hide History column")
                  : (model.sidePaneMode == .pullRequests ? "Show Pull requests column" : "Show History column"))

            Toggle(isOn: $model.showFiles) {
                Image(systemName: "list.bullet.indent")
            }
            .toggleStyle(.button)
            .help(model.showFiles ? "Hide Changed files column" : "Show Changed files column")
        }
    }

    private func upstreamBadge(for snapshot: BranchSnapshot?) -> String? {
        guard let snapshot, snapshot.remoteTrackingBranch != nil else { return nil }
        let ahead = snapshot.aheadOfRemote ?? 0
        let behind = snapshot.behindRemote ?? 0
        if ahead == 0, behind == 0 { return "✓" }
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined()
    }

    private func upstreamBadgeHelp(for snapshot: BranchSnapshot?) -> String? {
        guard let snapshot, let tracking = snapshot.remoteTrackingBranch else {
            return "No upstream configured for this branch"
        }
        let ahead = snapshot.aheadOfRemote ?? 0
        let behind = snapshot.behindRemote ?? 0
        if ahead == 0, behind == 0 {
            return "In sync with \(tracking)"
        }
        var parts: [String] = []
        if ahead > 0 {
            parts.append("\(ahead) unpushed commit\(ahead == 1 ? "" : "s") ahead of \(tracking)")
        }
        if behind > 0 {
            parts.append("\(behind) commit\(behind == 1 ? "" : "s") behind \(tracking)")
        }
        return parts.joined(separator: " · ")
    }

    private func upstreamBadgeStyle(for snapshot: BranchSnapshot?) -> BranchBadgeStyle {
        guard let snapshot, snapshot.remoteTrackingBranch != nil else { return .neutral }
        let ahead = snapshot.aheadOfRemote ?? 0
        let behind = snapshot.behindRemote ?? 0
        if behind > 0 { return .warning }
        if ahead > 0 { return .emphasis }
        return .success
    }
}

private enum BranchBadgeStyle {
    case neutral
    case success
    case emphasis
    case warning

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return .secondary
        case .emphasis: return Color.accentColor
        case .warning: return .orange
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
                HStack(spacing: 2) {
                    if ahead > 0 {
                        Text("↑\(ahead)")
                            .foregroundStyle(Color.accentColor)
                    }
                    if behind > 0 {
                        Text("↓\(behind)")
                            .foregroundStyle(.orange)
                    }
                    if ahead == 0, behind == 0 {
                        Text("↑0↓0")
                            .foregroundStyle(.secondary)
                    }
                }
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

private struct WorktreeMenu: View {
    @ObservedObject var model: RepoSession

    var body: some View {
        Menu {
            if model.worktrees.isEmpty {
                Text("No worktrees")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.worktrees) { worktree in
                    Button {
                        Task { await model.switchToWorktree(worktree) }
                    } label: {
                        if model.currentWorktree?.id == worktree.id {
                            Label(worktree.displayName, systemImage: "checkmark")
                        } else {
                            Text(worktree.displayName)
                        }
                    }
                    .help(worktree.path.path)
                }
            }
            Divider()
            Button("Reload Worktrees") {
                Task { await model.reloadWorktrees() }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WORKTREE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(model.currentWorktree?.path.lastPathComponent
                          ?? model.repoPath?.lastPathComponent
                          ?? "Select…")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 70, maxWidth: 140, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help(model.repoPath?.path ?? "Switch git worktree")
        .disabled(model.repoPath == nil)
    }
}

private struct CompareBranchControl: View {
    @ObservedObject var model: RepoSession

    private var behindCount: Int {
        model.snapshot?.compareAheadCount ?? 0
    }

    private var localCompareBehind: Int {
        model.snapshot?.localCompareBehindCount ?? 0
    }

    private var compareTip: String {
        model.snapshot?.compareTip ?? model.baseBranch
    }

    private var badge: String? {
        guard model.snapshot != nil else { return nil }
        return behindCount > 0 ? "↓\(behindCount)" : "✓"
    }

    private var badgeHelp: String? {
        guard model.snapshot != nil else { return nil }
        if behindCount > 0 {
            var text = "\(model.selectedBranch) is \(behindCount) commit\(behindCount == 1 ? "" : "s") behind \(compareTip)."
            if localCompareBehind > 0, compareTip != model.baseBranch {
                text += " Local \(model.baseBranch) is also \(localCompareBehind) behind \(compareTip)."
            }
            text += " Refresh fetches remotes first."
            return text
        }
        if localCompareBehind > 0, compareTip != model.baseBranch {
            return "\(model.selectedBranch) includes all commits from \(compareTip). Local \(model.baseBranch) is \(localCompareBehind) commit\(localCompareBehind == 1 ? "" : "s") behind \(compareTip)."
        }
        return "\(model.selectedBranch) includes all commits from \(compareTip)"
    }

    var body: some View {
        HStack(spacing: 8) {
            BranchMenu(
                title: "Compare",
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                value: model.baseBranch,
                options: model.branches,
                tipDates: model.branchTipDates,
                emphasized: false,
                badge: badge,
                badgeHelp: badgeHelp,
                badgeStyle: behindCount > 0 ? .warning : .success,
                helpText: "Branch to compare against (merge-base)"
            ) { model.selectBaseBranch($0) }

            if behindCount > 0 {
                Button {
                    Task { await model.updateFromCompare() }
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isLoading || model.isUpdatingFromCompare || model.selectedBranch == model.baseBranch)
                .help("Merge \(behindCount) commit\(behindCount == 1 ? "" : "s") from \(compareTip) into \(model.selectedBranch)")
            } else if localCompareBehind > 0, compareTip != model.baseBranch {
                Text("↓\(localCompareBehind)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
                    .help("Local \(model.baseBranch) is \(localCompareBehind) commit\(localCompareBehind == 1 ? "" : "s") behind \(compareTip). Your branch already includes those commits.")

                Button {
                    Task { await model.updateLocalCompare() }
                } label: {
                    Label("Update \(model.baseBranch)", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isLoading || model.isUpdatingFromCompare)
                .help("Fast-forward local \(model.baseBranch) by \(localCompareBehind) commit\(localCompareBehind == 1 ? "" : "s") to \(compareTip). Your branch already includes those commits.")
            }
        }
    }
}

private enum BranchSortMode: String, CaseIterable, Identifiable {
    case name
    case date

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date"
        }
    }
}

private struct BranchMenu: View {
    let title: String
    let icon: String
    let value: String
    let options: [String]
    var tipDates: [String: Date] = [:]
    let emphasized: Bool
    var badge: String? = nil
    var badgeHelp: String? = nil
    var badgeStyle: BranchBadgeStyle = .neutral
    var helpText: String = ""
    let onSelect: (String) -> Void

    @State private var isOpen = false
    @State private var query = ""
    @AppStorage("BranchLens.branchSortMode") private var sortModeRaw: String = BranchSortMode.name.rawValue

    private var sortMode: BranchSortMode {
        BranchSortMode(rawValue: sortModeRaw) ?? .name
    }

    private var filteredOptions: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty
            ? options
            : options.filter { $0.localizedCaseInsensitiveContains(q) }
        switch sortMode {
        case .name:
            return base.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .date:
            return base.sorted { lhs, rhs in
                let ld = tipDates[lhs] ?? .distantPast
                let rd = tipDates[rhs] ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    private var popoverWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let longest = options
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 180
        // Icon + paddings + optional relative-date column; clamp for extreme names.
        let dateExtra: CGFloat = sortMode == .date ? 78 : 0
        return min(max(ceil(longest) + 52 + dateExtra, 260), 720)
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
                            .layoutPriority(0)
                        if let badge {
                            Text(badge)
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(badgeStyle.color)
                                .fixedSize()
                                .layoutPriority(1)
                                .help(badgeHelp ?? badge)
                        }
                    }
                }
                .frame(minWidth: emphasized ? 160 : 110, maxWidth: emphasized ? 280 : 220, alignment: .leading)

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
        .help({
            var lines: [String] = []
            if !helpText.isEmpty { lines.append(helpText) }
            if !value.isEmpty { lines.append(value) }
            if let badgeHelp { lines.append(badgeHelp) }
            return lines.joined(separator: "\n")
        }())
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

            Picker("Sort", selection: Binding(
                get: { sortMode },
                set: { sortModeRaw = $0.rawValue }
            )) {
                ForEach(BranchSortMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Sort branches by name or newest tip date")

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
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer(minLength: 0)
                                    if sortMode == .date, let date = tipDates[branch] {
                                        Text(date, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .fixedSize()
                                    }
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
                            .help(branchHelp(for: branch))
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .frame(width: popoverWidth)
    }

    private func branchHelp(for branch: String) -> String {
        if let date = tipDates[branch] {
            let formatted = date.formatted(date: .abbreviated, time: .shortened)
            return "Select \(branch)\nTip: \(formatted)"
        }
        return "Select \(branch)"
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
                Group {
                    switch model.sidePaneMode {
                    case .history:
                        CommitsPane(model: model)
                    case .pullRequests:
                        PullRequestsPane(model: model)
                    }
                }
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

            Group {
                if case .fileLog = model.inspectorMode {
                    FileLogView(model: model)
                } else {
                    FileInspectorView(model: model, focusedSearch: focusedSearch)
                }
            }
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("History")
                            .font(.headline)
                        Spacer()
                        if model.isLoadingWorkingTree {
                            ProgressView().controlSize(.mini)
                        }
                        authorFilterMenu
                    }

                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { model.includeLocalChanges },
                            set: { model.setIncludeLocalChanges($0) }
                        )) {
                            Text("Include local changes")
                                .font(.caption.weight(.semibold))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Color.accentColor)
                        .help("Show Staged/Unstaged scopes and merge local edits into All changes")

                        Spacer(minLength: 0)

                        if model.isLoadingWorkingTree && !model.hasLocalChanges {
                            ProgressView()
                                .controlSize(.mini)
                        } else if model.hasLocalChanges {
                            HStack(spacing: 6) {
                                Text("\(model.localChangeFileCount)f")
                                    .foregroundStyle(.secondary)
                                    .help("\(model.localChangeFileCount) local file\(model.localChangeFileCount == 1 ? "" : "s") changed")
                                Text("+\(model.localChangeAdditions)")
                                    .foregroundStyle(AppTheme.additionText)
                                    .help("\(model.localChangeAdditions) lines added locally")
                                Text("−\(model.localChangeDeletions)")
                                    .foregroundStyle(AppTheme.deletionText)
                                    .help("\(model.localChangeDeletions) lines deleted locally")
                            }
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                (model.includeLocalChanges
                                 ? Color.accentColor.opacity(0.12)
                                 : Color.orange.opacity(0.12)),
                                in: Capsule()
                            )
                            .help("Local working-tree changes (shown even when Include local changes is off)")
                        } else {
                            Text("Clean")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .help("No local staged or unstaged changes")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().opacity(0.45)

                if historyIsClean {
                    ContentUnavailableView(
                        "Clean",
                        systemImage: "checkmark.circle",
                        description: Text(cleanHistoryDescription)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        // Non-lazy top cards stay stable; lazy only the long commit list.
                        VStack(spacing: 8) {
                            AllChangesCard(
                                isSelected: model.changeScope == .combined,
                                commitCount: model.filteredCommits.count,
                                stagedCount: model.stagedWorkingTreeFiles.count,
                                unstagedCount: model.unstagedWorkingTreeFiles.count,
                                includeLocal: model.includeLocalChanges,
                                fileCount: allChangesFileCount,
                                additions: model.snapshot?.totalAdditions ?? 0,
                                deletions: model.snapshot?.totalDeletions ?? 0
                            ) {
                                model.selectCombined()
                            }

                            if model.includeLocalChanges {
                                LocalScopeCard(
                                    title: "Staged",
                                    subtitle: "Changes in the index, ready to commit",
                                    icon: "plus.circle.fill",
                                    tint: AppTheme.additionText,
                                    fileCount: model.stagedWorkingTreeFiles.count,
                                    isSelected: model.changeScope == .staged,
                                    contextActions: stagedContextActions
                                ) {
                                    model.selectStaged()
                                }

                                LocalScopeCard(
                                    title: "Unstaged",
                                    subtitle: "Working tree edits not yet staged",
                                    icon: "pencil.circle.fill",
                                    tint: Color.orange,
                                    fileCount: model.unstagedWorkingTreeFiles.count,
                                    isSelected: model.changeScope == .unstaged,
                                    contextActions: model.unstagedWorkingTreeFiles.isEmpty
                                        ? []
                                        : [LocalScopeContextAction(title: "Stage All") {
                                            Task { await model.stageAllUnstaged() }
                                        }]
                                ) {
                                    model.selectUnstaged()
                                }
                            }

                            if let notice = staleCompareHistoryNotice {
                                StaleCompareHistoryBanner(
                                    notice: notice,
                                    isUpdating: model.isUpdatingFromCompare,
                                    onUpdate: {
                                        Task { await model.updateLocalCompare() }
                                    }
                                )
                            }

                            if let merged = model.mergedIntoCompare, model.filteredCommits.isEmpty {
                                MergedIntoCompareCard(
                                    info: merged,
                                    onOpenPullRequest: { link in
                                        model.openCommitPullRequestInBrowser(link)
                                    }
                                )

                                if model.filteredMergedCommits.isEmpty {
                                    if merged.kind == .mergedPR {
                                        Text(model.selectedAuthors.isEmpty
                                              ? "No merged commits to show."
                                              : "No merged commits from selected authors.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 4)
                                    }
                                } else {
                                    LazyVStack(spacing: 8) {
                                        ForEach(model.filteredMergedCommits) { commit in
                                            CommitCard(
                                                commit: commit,
                                                pullRequest: model.pullRequest(forCommitHash: commit.hash) ?? merged.pullRequest,
                                                isSelected: {
                                                    if case .commit(let hash) = model.changeScope {
                                                        return hash == commit.hash
                                                    }
                                                    return false
                                                }(),
                                                onSelect: { model.selectCommit(commit) },
                                                onOpenPullRequest: { link in
                                                    model.openCommitPullRequestInBrowser(link)
                                                }
                                            )
                                        }
                                    }
                                }
                            } else if model.filteredCommits.isEmpty {
                                Text(model.selectedAuthors.isEmpty ? "No commits on this branch." : "No commits from selected authors.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(model.filteredCommits) { commit in
                                        CommitCard(
                                            commit: commit,
                                            pullRequest: model.pullRequest(forCommitHash: commit.hash),
                                            isSelected: {
                                                if case .commit(let hash) = model.changeScope {
                                                    return hash == commit.hash
                                                }
                                                return false
                                            }(),
                                            onSelect: { model.selectCommit(commit) },
                                            onOpenPullRequest: { link in
                                                model.openCommitPullRequestInBrowser(link)
                                            }
                                        )
                                    }
                                }
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
            // Always refresh local stats so the toggle row can show counts even when off.
            Task { await model.reloadWorkingTree() }
        }
        .onChange(of: model.includeLocalChanges) { _, enabled in
            if enabled {
                Task { await model.reloadWorkingTree() }
            }
        }
    }

    private var allChangesFileCount: Int {
        let branchCount = model.snapshot?.files.count ?? 0
        guard model.includeLocalChanges else { return branchCount }
        return Set(model.snapshot?.files.map(\.path) ?? []).union(model.workingTreeFiles.map(\.path)).count
    }

    /// No unique branch commits, no local edits to browse, and nothing useful in the merged fallback.
    private var historyIsClean: Bool {
        if !model.filteredCommits.isEmpty { return false }
        if model.includeLocalChanges && model.hasLocalChanges { return false }
        if let notice = staleCompareHistoryNotice, notice.inheritedCommitCount > 0 { return false }
        if !model.selectedAuthors.isEmpty,
           let snapshot = model.snapshot,
           !snapshot.commits.isEmpty {
            return false
        }
        if let merged = model.mergedIntoCompare {
            switch merged.kind {
            case .mergedPR:
                return model.filteredMergedCommits.isEmpty && model.selectedAuthors.isEmpty
            case .inSync, .contained:
                return true
            }
        }
        return model.selectedAuthors.isEmpty
    }

    private var cleanHistoryDescription: String {
        if let merged = model.mergedIntoCompare {
            switch merged.kind {
            case .inSync:
                return "In sync with \(merged.compareLabel) — nothing unique to review."
            case .contained:
                return "Contained in \(merged.compareLabel) — nothing unique to review."
            case .mergedPR:
                return "Nothing left to review on this branch."
            }
        }
        return "No commits or local changes in this scope."
    }

    private var stagedContextActions: [LocalScopeContextAction] {
        guard !model.stagedWorkingTreeFiles.isEmpty else { return [] }
        return [
            LocalScopeContextAction(title: "Commit") {
                model.openCommitSheet()
            },
            LocalScopeContextAction(title: "Unstage All") {
                Task { await model.unstageAllStaged() }
            },
        ]
    }

    private var staleCompareHistoryNotice: StaleCompareHistoryNotice? {
        guard let snapshot = model.snapshot else { return nil }
        let behind = snapshot.localCompareBehindCount
        let inherited = snapshot.staleCompareInheritedCommitCount
        guard behind > 0, inherited > 0, snapshot.compareTip != snapshot.baseBranch else { return nil }
        return StaleCompareHistoryNotice(
            localCompare: snapshot.baseBranch,
            compareTip: snapshot.compareTip,
            behindCount: behind,
            inheritedCommitCount: inherited
        )
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

private struct AllChangesCard: View {
    let isSelected: Bool
    let commitCount: Int
    let stagedCount: Int
    let unstagedCount: Int
    let includeLocal: Bool
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let action: () -> Void

    private var tint: Color { AppTheme.allChangesTint }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(tint)
                    Text("All changes")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(fileCount)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: Capsule())
                }
                Text(includeLocal
                     ? "Branch commits plus staged and unstaged local edits."
                     : "Review the whole branch as a single change set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("\(commitCount) commits")
                    if includeLocal {
                        Text("·")
                        Text("\(stagedCount)s/\(unstagedCount)u")
                            .help("\(stagedCount) staged, \(unstagedCount) unstaged")
                    }
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
                    .fill(isSelected ? tint.opacity(0.18) : tint.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.60) : tint.opacity(0.28), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(includeLocal
              ? "Show branch commits together with staged and unstaged local changes"
              : "Show all branch commits as one change set")
    }
}

private struct LocalScopeContextAction: Identifiable {
    var id: String { title }
    let title: String
    let action: () -> Void
}

private struct LocalScopeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let fileCount: Int
    let isSelected: Bool
    var contextActions: [LocalScopeContextAction] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(fileCount)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: Capsule())
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.16) : tint.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.55) : tint.opacity(0.22), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(title): \(fileCount) file\(fileCount == 1 ? "" : "s")")
        .contextMenu {
            ForEach(contextActions) { item in
                Button(item.title, action: item.action)
            }
        }
    }
}

private struct CommitSheet: View {
    @ObservedObject var model: RepoSession
    @FocusState private var messageFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canCommit: Bool {
        !model.commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.stagedWorkingTreeFiles.isEmpty
            && !model.isCommitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Commit")
                    .font(.headline)
                Spacer()
                Text("\(model.stagedWorkingTreeFiles.count) staged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.commitMessageDraft)
                        .font(.body.monospaced())
                        .focused($messageFocused)
                        .frame(minHeight: 120, maxHeight: 220)
                        .padding(8)
                        .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .disabled(model.isCommitting)
                }

                Toggle(isOn: $model.commitShouldPush) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Push after commit")
                            .font(.callout.weight(.medium))
                        Text(model.selectedBranch.isEmpty
                              ? "Push to the remote"
                              : "Push \(model.selectedBranch) to its remote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(model.isCommitting)

                if let error = model.errorMessage, model.isCommitSheetPresented {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Divider().opacity(0.45)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isCommitting)

                Spacer()

                Button {
                    Task {
                        await model.commitStaged(
                            message: model.commitMessageDraft,
                            push: model.commitShouldPush
                        )
                    }
                } label: {
                    if model.isCommitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(model.commitShouldPush ? "Commit & Push" : "Commit")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 340)
        .onAppear {
            DispatchQueue.main.async {
                messageFocused = true
            }
        }
    }
}

private struct StaleCompareHistoryNotice: Equatable {
    let localCompare: String
    let compareTip: String
    let behindCount: Int
    let inheritedCommitCount: Int
}

private struct StaleCompareHistoryBanner: View {
    let notice: StaleCompareHistoryNotice
    let isUpdating: Bool
    let onUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why extra commits / PR badges?")
                        .font(.caption.weight(.semibold))
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                onUpdate()
            } label: {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Update \(notice.localCompare)", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isUpdating)
            .help("Fast-forward local \(notice.localCompare) to \(notice.compareTip) so History only lists commits unique to this branch")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
        )
    }

    private var explanation: String {
        let commitWord = notice.inheritedCommitCount == 1 ? "commit" : "commits"
        let behindWord = notice.behindCount == 1 ? "commit" : "commits"
        return "\(notice.inheritedCommitCount) \(commitWord) below (and their PR badges) are already on \(notice.compareTip). They show up because History compares against local \(notice.localCompare), which is \(notice.behindCount) \(behindWord) behind. Update \(notice.localCompare) to hide them."
    }
}

private struct MergedIntoCompareCard: View {
    let info: MergedIntoCompareInfo
    let onOpenPullRequest: (CommitPullRequestLink) -> Void

    private var tint: Color {
        switch info.kind {
        case .mergedPR: return Color(red: 0.55, green: 0.40, blue: 0.90)
        case .inSync: return Color.accentColor
        case .contained: return .secondary
        }
    }

    private var title: String {
        switch info.kind {
        case .mergedPR: return "Fully merged into \(info.compareLabel)"
        case .inSync: return "In sync with \(info.compareLabel)"
        case .contained: return "Already contained in \(info.compareLabel)"
        }
    }

    private var subtitle: String {
        switch info.kind {
        case .mergedPR:
            return "This branch has no unique commits left versus \(info.compareLabel). Showing commits from its merged pull request."
        case .inSync:
            return "This branch tip matches \(info.compareLabel), so there are no unique commits to review. The tip may be a merge from another branch."
        case .contained:
            return "Every commit on this branch is already in \(info.compareLabel), but no merged PR was found for this branch head."
        }
    }

    private var icon: String {
        switch info.kind {
        case .mergedPR: return "checkmark.seal.fill"
        case .inSync: return "equal.circle.fill"
        case .contained: return "arrow.down.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pr = info.pullRequest {
                Button {
                    onOpenPullRequest(pr)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.caption.weight(.bold))
                        Text(pr.badgeLabel)
                            .font(.caption.weight(.bold))
                        Text(pr.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "safari")
                            .font(.caption)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open \(pr.badgeLabel): \(pr.title)")
            }

            if !info.commits.isEmpty {
                Text("\(info.commits.count) merged commit\(info.commits.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(info.kind == .contained ? 0.06 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(info.kind == .contained ? 0.22 : 0.35), lineWidth: 1)
        )
    }
}

private struct CommitCard: View {
    let commit: GitCommit
    let pullRequest: CommitPullRequestLink?
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenPullRequest: (CommitPullRequestLink) -> Void

    var body: some View {
        Button(action: onSelect) {
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
                HStack(spacing: 6) {
                    Text(commit.authoredDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if let pullRequest {
                        Button {
                            onOpenPullRequest(pullRequest)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.pull")
                                    .font(.caption2.weight(.bold))
                                Text(pullRequest.badgeLabel)
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(prBadgeColor(for: pullRequest))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(prBadgeColor(for: pullRequest).opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(pullRequest.badgeLabel): \(pullRequest.title)")
                    }
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
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.05), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(commit.shortHash): \(commit.subject)")
        .contextMenu {
            if let pullRequest {
                Button("Open \(pullRequest.badgeLabel)") {
                    onOpenPullRequest(pullRequest)
                }
            }
        }
    }

    private func prBadgeColor(for link: CommitPullRequestLink) -> Color {
        switch link.status {
        case "open":
            return link.isDraft ? .secondary : AppTheme.additionText
        case "merged":
            return Color(red: 0.55, green: 0.40, blue: 0.90)
        default:
            return .secondary
        }
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
                        Button {
                            model.openCrossFileSearch()
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Find in changed files (⌘⇧F)")

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

                    if !model.crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        activeCrossFileChip
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { model.preferFileSearch() }
                .onChange(of: model.fileNameQuery) { _, _ in
                    if !model.crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.scheduleCrossFileSearch()
                    }
                }

                Divider().opacity(0.45)

                if model.filteredFiles.isEmpty {
                    ContentUnavailableView(
                        model.visibleFiles.isEmpty ? "No file changes" : "No matching files",
                        systemImage: "folder",
                        description: Text(emptyFilesDescription)
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
                expandNewFolders()
            }
        }
        .onChange(of: model.fileTree) { _, _ in
            if model.filesLayout == .folders {
                // Only open newly appeared folders — don't reset expansion (avoids scroll jumps).
                expandNewFolders()
            }
        }
        .onAppear {
            if model.filesLayout == .folders {
                expandNewFolders()
            }
        }
    }

    private var emptyFilesDescription: String {
        if model.visibleFiles.isEmpty {
            return "Nothing changed in this scope."
        }
        if !model.crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No changed files contain that text in \(model.crossFileSearchMode.rawValue.lowercased())."
        }
        return "Try a different file name filter."
    }

    private var activeCrossFileChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Button {
                model.openCrossFileSearch()
            } label: {
                HStack(spacing: 6) {
                    Text(model.crossFileSearchMode.rawValue)
                        .foregroundStyle(.secondary)
                    Text(model.crossFileQuery)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.isSearchingCrossFile {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("\(model.crossFileMatchCounts.count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Edit find-in-files search")

            Spacer(minLength: 0)

            Button {
                model.clearCrossFileSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear find-in-files search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var flatList: some View {
        List(selection: fileSelection) {
            ForEach(model.filteredFiles) { file in
                FileRow(
                    file: file,
                    showDirectory: true,
                    matchCount: model.crossFileMatchCounts[file.id]
                )
                    .tag(file.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                    .contextMenu { fileContextMenu(for: file) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Stable identity per scope so SwiftUI doesn't rebuild mid-scroll on minor reloads.
        .id(fileListIdentity)
        .onAppear { model.preferFileSearch() }
        .simultaneousGesture(TapGesture().onEnded { model.preferFileSearch() })
        .help("⌘-click to add/remove; ⇧-click to select a range")
    }

    private var fileListIdentity: String {
        switch model.changeScope {
        case .combined: return "combined-\(model.includeLocalChanges)"
        case .staged: return "staged"
        case .unstaged: return "unstaged"
        case .commit(let hash): return "commit-\(hash)"
        }
    }

    private var folderList: some View {
        // Eager VStack (not LazyVStack): lazy stacks estimate height while scrolling,
        // which makes the scrollbar thumb jump between different sizes.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.fileTree) { node in
                    FolderTreeRow(
                        node: node,
                        depth: 0,
                        selectedFileIDs: model.selectedFileIDs,
                        matchCounts: model.crossFileMatchCounts,
                        expandedFolderIDs: $expandedFolderIDs,
                        canStage: { model.isUnstaged($0) },
                        canUnstage: { model.isStaged($0) },
                        onSelect: { file in
                            model.preferFileSearch()
                            model.handleFileClick(file)
                        },
                        onLog: { file in
                            model.openFileLog(for: file)
                        },
                        onRevealInFinder: { file in
                            revealInFinder(relativePath: file.path)
                        },
                        onStage: { file in
                            Task { await model.stageFile(file) }
                        },
                        onUnstage: { file in
                            Task { await model.unstageFile(file) }
                        },
                        onStageSelected: model.selectedFilesStagable.isEmpty ? nil : {
                            Task { await model.stageSelectedFiles() }
                        },
                        onUnstageSelected: model.selectedFilesUnstagable.isEmpty ? nil : {
                            Task { await model.unstageSelectedFiles() }
                        },
                        multiSelectionCount: model.selectedFileIDs.count
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .id(fileListIdentity)
        .simultaneousGesture(TapGesture().onEnded { model.preferFileSearch() })
    }

    @ViewBuilder
    private func fileContextMenu(for file: ChangedFile) -> some View {
        let multi = model.selectedFileIDs.count > 1 && model.selectedFileIDs.contains(file.id)
        if multi {
            if !model.selectedFilesStagable.isEmpty {
                Button("Stage Selected") {
                    Task { await model.stageSelectedFiles() }
                }
            }
            if !model.selectedFilesUnstagable.isEmpty {
                Button("Unstage Selected") {
                    Task { await model.unstageSelectedFiles() }
                }
            }
            if !model.selectedFilesStagable.isEmpty || !model.selectedFilesUnstagable.isEmpty {
                Divider()
            }
        } else {
            if model.isUnstaged(file) {
                Button("Stage File") {
                    Task { await model.stageFile(file) }
                }
            }
            if model.isStaged(file) {
                Button("Unstage File") {
                    Task { await model.unstageFile(file) }
                }
            }
            if model.isUnstaged(file) || model.isStaged(file) {
                Divider()
            }
        }
        Button("Log") {
            model.openFileLog(for: file)
        }
        Button("Copy File Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
        Button("Find in Finder") {
            revealInFinder(relativePath: file.path)
        }
    }

    private func revealInFinder(relativePath: String) {
        guard let repo = model.repoPath else { return }
        let url = repo.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Deleted / missing: open the parent folder.
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path
            )
        }
    }

    private var fileSelection: Binding<Set<String>> {
        Binding(
            get: { model.selectedFileIDs },
            set: { newValue in
                model.preferFileSearch()
                model.applyListSelection(newValue)
            }
        )
    }

    private func expandNewFolders() {
        expandedFolderIDs.formUnion(collectFolderIDs(model.fileTree))
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
    let selectedFileIDs: Set<String>
    var matchCounts: [String: Int] = [:]
    @Binding var expandedFolderIDs: Set<FileTreeNode.ID>
    var canStage: (ChangedFile) -> Bool = { _ in false }
    var canUnstage: (ChangedFile) -> Bool = { _ in false }
    let onSelect: (ChangedFile) -> Void
    let onLog: (ChangedFile) -> Void
    let onRevealInFinder: (ChangedFile) -> Void
    var onStage: ((ChangedFile) -> Void)? = nil
    var onUnstage: ((ChangedFile) -> Void)? = nil
    var onStageSelected: (() -> Void)? = nil
    var onUnstageSelected: (() -> Void)? = nil
    var multiSelectionCount: Int = 0

    private var isExpanded: Bool {
        expandedFolderIDs.contains(node.id)
    }

    var body: some View {
        if let file = node.file {
            Button {
                onSelect(file)
            } label: {
                FileRow(
                    file: file,
                    showDirectory: false,
                    matchCount: matchCounts[file.id]
                )
                    .padding(.leading, CGFloat(depth) * Self.iconWidth + Self.iconWidth)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedFileIDs.contains(file.id) ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(file.path)
            .contextMenu {
                let multi = multiSelectionCount > 1 && selectedFileIDs.contains(file.id)
                if multi {
                    if let onStageSelected {
                        Button("Stage Selected") { onStageSelected() }
                    }
                    if let onUnstageSelected {
                        Button("Unstage Selected") { onUnstageSelected() }
                    }
                    if onStageSelected != nil || onUnstageSelected != nil {
                        Divider()
                    }
                } else {
                    if canStage(file), let onStage {
                        Button("Stage File") { onStage(file) }
                    }
                    if canUnstage(file), let onUnstage {
                        Button("Unstage File") { onUnstage(file) }
                    }
                    if canStage(file) || canUnstage(file) {
                        Divider()
                    }
                }
                Button("Log") { onLog(file) }
                Button("Copy File Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
                Button("Find in Finder") { onRevealInFinder(file) }
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
                            selectedFileIDs: selectedFileIDs,
                            matchCounts: matchCounts,
                            expandedFolderIDs: $expandedFolderIDs,
                            canStage: canStage,
                            canUnstage: canUnstage,
                            onSelect: onSelect,
                            onLog: onLog,
                            onRevealInFinder: onRevealInFinder,
                            onStage: onStage,
                            onUnstage: onUnstage,
                            onStageSelected: onStageSelected,
                            onUnstageSelected: onUnstageSelected,
                            multiSelectionCount: multiSelectionCount
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
    var matchCount: Int? = nil

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

            if let matchCount, matchCount > 0 {
                Text("\(matchCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .help("\(matchCount) match\(matchCount == 1 ? "" : "es")")
            }

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

// MARK: - Find in files

private struct CrossFileSearchSheet: View {
    @ObservedObject var model: RepoSession
    @FocusState private var queryFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: [(file: ChangedFile, count: Int)] {
        model.nameFilteredFiles.compactMap { file in
            guard let count = model.crossFileMatchCounts[file.id] else { return nil }
            return (file, count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Find in Files")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search in changed files…", text: $model.crossFileQuery)
                        .textFieldStyle(.plain)
                        .focused($queryFocused)
                        .onSubmit { model.scheduleCrossFileSearch() }
                    if model.isSearchingCrossFile {
                        ProgressView().controlSize(.small)
                    } else if !model.crossFileQuery.isEmpty {
                        Button {
                            model.clearCrossFileSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Picker("Search scope", selection: $model.crossFileSearchMode) {
                    ForEach(CrossFileSearchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Full Source searches file contents; Modifications searches only added/removed diff lines")

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider().opacity(0.45)

            Group {
                if model.crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Search changed files",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Choose Full Source or Modifications, then enter a search string.")
                    )
                } else if model.isSearchingCrossFile && matches.isEmpty {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if matches.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("No changed files contain that text in \(model.crossFileSearchMode.rawValue.lowercased()).")
                    )
                } else {
                    List(matches, id: \.file.id) { item in
                        Button {
                            model.selectFile(item.file)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(item.file.status.rawValue)
                                    .font(.caption.weight(.bold).monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((item.file.path as NSString).lastPathComponent)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(item.file.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: 4)
                                Text("\(item.count)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            model.scheduleCrossFileSearch()
            DispatchQueue.main.async {
                queryFocused = true
            }
        }
        .onChange(of: model.crossFileQuery) { _, _ in
            model.scheduleCrossFileSearch()
        }
        .onChange(of: model.crossFileSearchMode) { _, _ in
            model.scheduleCrossFileSearch()
        }
    }

    private var statusLine: String {
        let query = model.crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "Searches the current Changed files scope."
        }
        if model.isSearchingCrossFile {
            return "Searching \(model.nameFilteredFiles.count) file\(model.nameFilteredFiles.count == 1 ? "" : "s")…"
        }
        return "\(matches.count) matching file\(matches.count == 1 ? "" : "s") · \(model.crossFileSearchMode.rawValue)"
    }
}

// MARK: - Inspector

private struct FileInspectorView: View {
    @ObservedObject var model: RepoSession
    var focusedSearch: FocusState<SearchFocusTarget?>.Binding

    var body: some View {
        PanelChrome {
            VStack(alignment: .leading, spacing: 0) {
                if model.hasMultiFileSelection {
                    multiSelectPanel
                } else {
                    header
                    Divider().opacity(0.45)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if !model.hasMultiFileSelection {
                model.preferContentSearch()
            }
        })
    }

    private var multiSelectPanel: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "doc.on.doc")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(model.selectedFileIDs.count) files selected")
                .font(.title3.weight(.semibold))
            Text("⌘-click to add or remove · ⇧-click for a range")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if !model.selectedFilesStagable.isEmpty {
                    Button("Stage Selected") {
                        Task { await model.stageSelectedFiles() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Stage \(model.selectedFilesStagable.count) selected file\(model.selectedFilesStagable.count == 1 ? "" : "s")")
                }
                if !model.selectedFilesUnstagable.isEmpty {
                    Button("Unstage Selected") {
                        Task { await model.unstageSelectedFiles() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Unstage \(model.selectedFilesUnstagable.count) selected file\(model.selectedFilesUnstagable.count == 1 ? "" : "s")")
                }
            }

            if model.selectedFilesStagable.isEmpty && model.selectedFilesUnstagable.isEmpty {
                Text("Selected files are not in the working tree staging areas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
                if showsRevisionModes {
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
                }

                if let file = model.selectedFile, model.isUnstaged(file) {
                    Button("Stage File") {
                        Task { await model.stageFile(file) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Stage this file into the index")
                }
                if let file = model.selectedFile, model.isStaged(file) {
                    Button("Unstage File") {
                        Task { await model.unstageFile(file) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Unstage this file from the index")
                }

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

    /// Added/deleted files have no meaningful before/after pair — show content only.
    private var showsRevisionModes: Bool {
        guard let status = model.selectedFile?.status else { return true }
        switch status {
        case .added, .deleted: return false
        default: return true
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingFile && model.fileDiff.isEmpty && model.beforeContents == nil && model.afterContents == nil {
            ProgressView("Loading file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedFile == nil {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a changed file to inspect Diff, Before, or After.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedFile?.status == .added {
            CodePane(
                title: "Contents",
                subtitle: model.afterLabel,
                accent: AppTheme.additionText,
                source: model.afterContents,
                path: model.selectedFile?.path ?? "file.txt",
                placeholder: "New file is empty or could not be loaded.",
                lineCount: model.afterLineCount,
                searchQuery: model.contentQuery
            )
            .id("added-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedFile?.status == .deleted {
            CodePane(
                title: "Contents",
                subtitle: model.beforeLabel,
                accent: AppTheme.deletionText,
                source: model.beforeContents,
                path: model.selectedFile?.oldPath ?? model.selectedFile?.path ?? "file.txt",
                placeholder: "Deleted file could not be loaded.",
                lineCount: model.beforeLineCount,
                searchQuery: model.contentQuery
            )
            .id("deleted-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.fileViewMode {
            case .diff:
                if let file = model.selectedFile,
                   model.changeScope == .unstaged || model.changeScope == .staged {
                    HunkDiffView(
                        text: model.fileDiff,
                        path: file.path,
                        searchQuery: model.contentQuery,
                        actionTitle: model.changeScope == .staged ? "Unstage Hunk" : "Stage Hunk"
                    ) { hunk in
                        Task {
                            if model.changeScope == .staged {
                                await model.unstageHunk(hunk, for: file)
                            } else {
                                await model.stageHunk(hunk, for: file)
                            }
                        }
                    }
                    .id("hunks-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DiffScrollView(
                        text: model.fileDiff,
                        path: model.selectedFile?.path ?? "file.txt",
                        searchQuery: model.contentQuery
                    )
                    .id("diff-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .before:
                CodePane(
                    title: "Before",
                    subtitle: model.beforeLabel,
                    accent: AppTheme.deletionText,
                    source: model.beforeContents,
                    path: model.selectedFile?.oldPath ?? model.selectedFile?.path ?? "file.txt",
                    placeholder: "File did not exist in this revision.",
                    lineCount: model.beforeLineCount,
                    searchQuery: model.contentQuery,
                    emphasizedLines: model.compareChangedLineNumbers.deleted,
                    lineEmphasis: .deletion
                )
                .id("before-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
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
                    searchQuery: model.contentQuery,
                    emphasizedLines: model.compareChangedLineNumbers.added,
                    lineEmphasis: .addition
                )
                .id("after-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .compare:
                let changed = model.compareChangedLineNumbers
                HStack(spacing: 10) {
                    CodePane(
                        title: "Before",
                        subtitle: model.beforeLabel,
                        accent: AppTheme.deletionText,
                        source: model.beforeContents,
                        path: model.selectedFile?.oldPath ?? model.selectedFile?.path ?? "file.txt",
                        placeholder: "File did not exist in this revision.",
                        lineCount: model.beforeLineCount,
                        searchQuery: model.contentQuery,
                        emphasizedLines: changed.deleted,
                        lineEmphasis: .deletion
                    )
                    CodePane(
                        title: "After",
                        subtitle: model.afterLabel,
                        accent: AppTheme.additionText,
                        source: model.afterContents,
                        path: model.selectedFile?.path ?? "file.txt",
                        placeholder: "File does not exist in this revision.",
                        lineCount: model.afterLineCount,
                        searchQuery: model.contentQuery,
                        emphasizedLines: changed.added,
                        lineEmphasis: .addition
                    )
                }
                .id("compare-\(model.contentRefreshNonce)-\(model.selectedFileID ?? "")")
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

#Preview {
    ContentView()
}
