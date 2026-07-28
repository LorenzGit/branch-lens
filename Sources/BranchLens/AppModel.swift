import AppKit
import BranchLensCore
import Foundation
import SwiftUI

enum FileViewMode: String, CaseIterable, Identifiable {
    case diff = "Diff"
    case before = "Before"
    case after = "After"
    case compare = "Compare"

    var id: String { rawValue }
}

enum ChangeScope: Equatable, Hashable {
    /// Branch commits since Compare, plus local staged/unstaged.
    case combined
    case commit(String)
    case staged
    case unstaged

    var cacheKeyPart: String {
        switch self {
        case .combined: return "combined"
        case .commit(let hash): return "commit:\(hash)"
        case .staged: return "staged"
        case .unstaged: return "unstaged"
        }
    }
}

enum SearchFocusTarget: Hashable {
    case fileFilter
    case content
}

enum SidePaneMode: String, CaseIterable, Identifiable {
    case history = "History"
    case pullRequests = "PRs"

    var id: String { rawValue }
}

enum InspectorMode: Equatable {
    case file
    case fileLog(path: String)
}

struct FileInspectorPayload: Sendable {
    var diff: String
    var before: String?
    var after: String?
    var beforeLabel: String
    var afterLabel: String
}

@MainActor
final class RepoSession: ObservableObject, Identifiable {
    let id: UUID
    var onStateChange: (() -> Void)?

    @Published var repoPath: URL?
    @Published var branches: [String] = []
    @Published var selectedBranch: String = ""
    @Published var baseBranch: String = ""
    @Published var snapshot: BranchSnapshot?
    @Published var changeScope: ChangeScope = .combined
    @Published var selectedFileID: String?
    @Published var fileViewMode: FileViewMode = .diff
    @Published var visibleFiles: [ChangedFile] = []
    @Published var fileDiff: String = ""
    @Published var beforeContents: String?
    @Published var afterContents: String?
    @Published var beforeLabel: String = "Before"
    @Published var afterLabel: String = "After"
    @Published var selectedAuthors: Set<String> = []
    @Published var fileNameQuery: String = ""
    @Published var contentQuery: String = ""
    @Published var filesLayout: FilesLayoutMode = .folders
    @Published var showHistory = true
    @Published var showFiles = true
    @Published var sidePaneMode: SidePaneMode = .history
    @Published var inspectorMode: InspectorMode = .file
    /// When on, History shows Staged/Unstaged and All changes merges local edits.
    @Published var includeLocalChanges = false
    @Published var isLoading = false
    @Published var isLoadingFile = false
    @Published var isUpdatingFromCompare = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var searchFocusTarget: SearchFocusTarget = .content
    /// Bumped to force the matching search field to become first responder (⌘F).
    @Published var searchFocusNonce: Int = 0

    // Working tree (local staged / unstaged)
    @Published var workingTreeFiles: [WorkingTreeFile] = []
    @Published var isLoadingWorkingTree = false

    // Worktrees
    @Published var worktrees: [GitWorktree] = []

    // File log
    @Published var fileLogEntries: [FileLogEntry] = []
    @Published var selectedFileLogID: String?
    @Published var fileLogDiff: String = ""
    @Published var fileLogContainingBranches: [String] = []
    @Published var isLoadingFileLog = false
    @Published var isLoadingFileLogDiff = false
    @Published var fileLogError: String?

    // Pull requests
    @Published var pullRequestFilter: PullRequestState = .open
    @Published var pullRequests: [PullRequestSummary] = []
    @Published var selectedPullRequestAuthors: Set<String> = []
    @Published var selectedPullRequestID: Int?
    @Published var isLoadingPullRequests = false
    @Published var pullRequestError: String?

    private let git = GitService()
    private let github = GitHubService()
    private var loadTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var scopeTask: Task<Void, Never>?
    private var workingTreeTask: Task<Void, Never>?
    private var fileLogTask: Task<Void, Never>?
    private var fileLogDiffTask: Task<Void, Never>?
    private var pullRequestTask: Task<Void, Never>?
    private var inspectorCache: [String: FileInspectorPayload] = [:]
    private let cacheLimit = 96

    init(id: UUID = UUID()) {
        self.id = id
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    func makeSnapshot() -> TabSnapshot? {
        guard let repoPath else { return nil }
        let commitHash: String?
        let combined: Bool
        switch changeScope {
        case .combined, .staged, .unstaged:
            combined = true
            commitHash = nil
        case .commit(let hash):
            combined = false
            commitHash = hash
        }
        return TabSnapshot(
            id: id,
            repoPath: repoPath.path,
            selectedBranch: selectedBranch,
            baseBranch: baseBranch,
            scopeIsCombined: combined,
            selectedCommitHash: commitHash,
            selectedFileID: selectedFileID,
            fileViewMode: fileViewMode.rawValue,
            filesLayout: filesLayout.rawValue,
            showHistory: showHistory,
            showFiles: showFiles,
            selectedAuthors: Array(selectedAuthors).sorted(),
            fileNameQuery: fileNameQuery,
            includeLocalChanges: includeLocalChanges
        )
    }

    func restore(from state: TabSnapshot) async {
        showHistory = state.showHistory
        showFiles = state.showFiles
        filesLayout = FilesLayoutMode(rawValue: state.filesLayout) ?? .folders
        fileViewMode = FileViewMode(rawValue: state.fileViewMode) ?? .diff
        selectedAuthors = Set(state.selectedAuthors)
        fileNameQuery = state.fileNameQuery
        selectedFileID = state.selectedFileID
        includeLocalChanges = state.includeLocalChanges ?? false

        await openRepository(
            at: URL(fileURLWithPath: state.repoPath),
            preferredBranch: state.selectedBranch,
            preferredBase: state.baseBranch,
            resetTransientState: false
        )

        guard repoPath != nil else { return }

        if state.scopeIsCombined {
            changeScope = .combined
        } else if let hash = state.selectedCommitHash,
                  snapshot?.commits.contains(where: { $0.hash == hash }) == true {
            changeScope = .commit(hash)
        } else {
            changeScope = .combined
        }

        selectedFileID = state.selectedFileID
        if includeLocalChanges {
            await reloadWorkingTree()
        }
        await reloadVisibleFiles()
        notifyStateChange()
    }

    var selectedFile: ChangedFile? {
        guard let selectedFileID else { return nil }
        return visibleFiles.first { $0.id == selectedFileID }
            ?? filteredFiles.first { $0.id == selectedFileID }
    }

    var stagedWorkingTreeFiles: [WorkingTreeFile] {
        workingTreeFiles.filter { $0.area == .staged }
    }

    var unstagedWorkingTreeFiles: [WorkingTreeFile] {
        workingTreeFiles.filter { $0.area == .unstaged }
    }

    var currentWorktree: GitWorktree? {
        guard let repoPath else { return nil }
        let standardized = repoPath.standardizedFileURL
        return worktrees.first { $0.path.standardizedFileURL == standardized }
    }

    var branchAuthors: [String] {
        guard let snapshot else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for commit in snapshot.commits {
            if seen.insert(commit.authorName).inserted {
                names.append(commit.authorName)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var filteredCommits: [GitCommit] {
        guard let snapshot else { return [] }
        if selectedAuthors.isEmpty { return snapshot.commits }
        return snapshot.commits.filter { selectedAuthors.contains($0.authorName) }
    }

    var filteredFiles: [ChangedFile] {
        let query = fileNameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleFiles }
        return visibleFiles.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var pullRequestAuthors: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for pr in pullRequests {
            if seen.insert(pr.authorLogin).inserted {
                names.append(pr.authorLogin)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var filteredPullRequests: [PullRequestSummary] {
        if selectedPullRequestAuthors.isEmpty { return pullRequests }
        return pullRequests.filter { selectedPullRequestAuthors.contains($0.authorLogin) }
    }

    var fileTree: [FileTreeNode] {
        FileTreeNode.build(from: filteredFiles)
    }

    /// Commit currently driving the Changed files scope (selected commit, or tip when combined).
    var activeScopeCommit: GitCommit? {
        switch changeScope {
        case .commit(let hash):
            return snapshot?.commits.first(where: { $0.hash == hash })
                ?? filteredCommits.first(where: { $0.hash == hash })
        case .combined:
            return filteredCommits.first ?? snapshot?.commits.first
        case .staged, .unstaged:
            return nil
        }
    }

    var scopeCommitSummary: String {
        switch changeScope {
        case .combined:
            if let commit = activeScopeCommit {
                let date = commit.authoredDate.formatted(date: .abbreviated, time: .shortened)
                let base = "\(commit.shortHash) · \(commit.authorName) · \(date)"
                if includeLocalChanges, !workingTreeFiles.isEmpty {
                    return "\(base) · +\(workingTreeFiles.count) local"
                }
                return base
            }
            return includeLocalChanges && !workingTreeFiles.isEmpty ? "Local changes only" : "No commits"
        case .staged:
            return "Staged · \(stagedWorkingTreeFiles.count) file\(stagedWorkingTreeFiles.count == 1 ? "" : "s")"
        case .unstaged:
            return "Unstaged · \(unstagedWorkingTreeFiles.count) file\(unstagedWorkingTreeFiles.count == 1 ? "" : "s")"
        case .commit:
            guard let commit = activeScopeCommit else { return "Commit" }
            let date = commit.authoredDate.formatted(date: .abbreviated, time: .shortened)
            return "\(commit.shortHash) · \(commit.authorName) · \(date)"
        }
    }

    var repoDirectoryPath: String {
        repoPath?.path ?? ""
    }

    var visibleAdditions: Int { visibleFiles.reduce(0) { $0 + $1.additions } }
    var visibleDeletions: Int { visibleFiles.reduce(0) { $0 + $1.deletions } }

    var beforeLineCount: Int { TextUtilities.lineCount(beforeContents) }
    var afterLineCount: Int { TextUtilities.lineCount(afterContents) }

    var activeContentForSearch: String {
        switch fileViewMode {
        case .diff: return fileDiff
        case .before: return beforeContents ?? ""
        case .after: return afterContents ?? ""
        case .compare:
            return [beforeContents, afterContents].compactMap { $0 }.joined(separator: "\n")
        }
    }

    var contentMatchCount: Int {
        TextUtilities.matchCount(in: activeContentForSearch, query: contentQuery)
    }

    func openRepository(
        at url: URL,
        preferredBranch: String? = nil,
        preferredBase: String? = nil,
        resetTransientState: Bool = true
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let root = try await git.validateRepository(at: url)
            repoPath = root
            RecentRepos.remember(root)

            let listed = try await git.listBranches(in: root)
            branches = listed
            let memory = RepoMemory.load(for: root)
            let current = try await git.currentBranch(in: root)
            let detectedBase = try await git.detectBaseBranch(in: root, branches: listed) ?? ""

            if let preferredBranch, listed.contains(preferredBranch) {
                selectedBranch = preferredBranch
            } else if let remembered = memory?.branch, listed.contains(remembered) {
                selectedBranch = remembered
            } else if let current, listed.contains(current), current != detectedBase {
                selectedBranch = current
            } else if let other = listed.first(where: { $0 != detectedBase }) {
                selectedBranch = other
            } else {
                selectedBranch = listed.first ?? ""
            }

            if let preferredBase, listed.contains(preferredBase) {
                baseBranch = preferredBase
            } else if let rememberedBase = memory?.base, listed.contains(rememberedBase) {
                baseBranch = rememberedBase
            } else {
                baseBranch = detectedBase
            }

            if resetTransientState {
                selectedAuthors = []
                fileNameQuery = ""
                contentQuery = ""
                changeScope = .combined
                selectedFileID = nil
            }
            clearInspectorCache()
            await reloadSnapshot(resetScope: resetTransientState)
            notifyStateChange()
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    func selectBranch(_ branch: String) {
        selectedBranch = branch
        persistMemory()
        clearInspectorCache()
        notifyStateChange()
        Task { await reloadSnapshot(resetScope: true) }
    }

    func selectBaseBranch(_ branch: String) {
        baseBranch = branch
        persistMemory()
        clearInspectorCache()
        notifyStateChange()
        Task { await reloadSnapshot(resetScope: true) }
    }

    func toggleAuthor(_ name: String) {
        if selectedAuthors.contains(name) {
            selectedAuthors.remove(name)
        } else {
            selectedAuthors.insert(name)
        }
        if case .commit(let hash) = changeScope {
            if !filteredCommits.contains(where: { $0.hash == hash }) {
                selectCombined()
            }
        }
        notifyStateChange()
    }

    func clearAuthorFilter() {
        selectedAuthors.removeAll()
        notifyStateChange()
    }

    func togglePullRequestAuthor(_ login: String) {
        if selectedPullRequestAuthors.contains(login) {
            selectedPullRequestAuthors.remove(login)
        } else {
            selectedPullRequestAuthors.insert(login)
        }
        if let selected = selectedPullRequestID,
           !filteredPullRequests.contains(where: { $0.number == selected }) {
            selectedPullRequestID = nil
        }
        notifyStateChange()
    }

    func clearPullRequestAuthorFilter() {
        selectedPullRequestAuthors.removeAll()
        notifyStateChange()
    }

    func selectCombined() {
        changeScope = .combined
        notifyStateChange()
        Task { await reloadVisibleFiles() }
    }

    func selectStaged() {
        includeLocalChanges = true
        changeScope = .staged
        notifyStateChange()
        Task { await reloadVisibleFiles() }
    }

    func selectUnstaged() {
        includeLocalChanges = true
        changeScope = .unstaged
        notifyStateChange()
        Task { await reloadVisibleFiles() }
    }

    func selectCommit(_ commit: GitCommit) {
        changeScope = .commit(commit.hash)
        notifyStateChange()
        Task { await reloadVisibleFiles() }
    }

    func setIncludeLocalChanges(_ enabled: Bool) {
        includeLocalChanges = enabled
        if !enabled, changeScope == .staged || changeScope == .unstaged {
            changeScope = .combined
        }
        notifyStateChange()
        Task {
            if enabled {
                await reloadWorkingTree()
            }
            await reloadVisibleFiles()
        }
    }

    /// Toolbar refresh: fetch remotes, then reload branches + snapshot.
    func refresh() async {
        await reloadSnapshot(resetScope: false, fetchFirst: true)
        await reloadWorktrees()
        await reloadWorkingTree()
        if sidePaneMode == .pullRequests {
            await loadPullRequests()
        }
        if case .fileLog(let path) = inspectorMode {
            await loadFileLog(path: path)
        }
    }

    func reloadWorkingTree() async {
        guard let repoPath else {
            workingTreeFiles = []
            return
        }
        workingTreeTask?.cancel()
        isLoadingWorkingTree = true
        workingTreeTask = Task {
            do {
                let files = try await git.workingTreeStatus(in: repoPath)
                guard !Task.isCancelled else { return }
                let previous = workingTreeFiles
                workingTreeFiles = files
                isLoadingWorkingTree = false
                // Avoid needless list reloads (they jump the Changed files scroller).
                let scopeNeedsLocal = changeScope == .staged
                    || changeScope == .unstaged
                    || (changeScope == .combined && includeLocalChanges)
                if scopeNeedsLocal, previous != files {
                    await reloadVisibleFiles()
                }
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                workingTreeFiles = []
                isLoadingWorkingTree = false
                errorMessage = error.localizedDescription
            }
        }
        await workingTreeTask?.value
    }

    func reloadWorktrees() async {
        guard let repoPath else {
            worktrees = []
            return
        }
        worktrees = (try? await git.listWorktrees(in: repoPath)) ?? []
    }

    func switchToWorktree(_ worktree: GitWorktree) async {
        guard worktree.path.standardizedFileURL != repoPath?.standardizedFileURL else { return }
        statusMessage = "Switching worktree…"
        await openRepository(
            at: worktree.path,
            preferredBranch: worktree.branch,
            preferredBase: baseBranch.isEmpty ? nil : baseBranch,
            resetTransientState: true
        )
        statusMessage = nil
    }

    /// Merge COMPARE (`baseBranch`) into the inspected BRANCH.
    func updateFromCompare() async {
        guard let repoPath else { return }
        guard !selectedBranch.isEmpty, !baseBranch.isEmpty else { return }
        guard selectedBranch != baseBranch else {
            errorMessage = "Branch and Compare are the same — nothing to update."
            return
        }

        isUpdatingFromCompare = true
        errorMessage = nil
        statusMessage = "Updating \(selectedBranch) from \(baseBranch)…"

        do {
            // Prefer fresh remote tips before merging.
            try? await git.fetchRemotes(in: repoPath)
            let tip = await git.resolveFreshTip(for: baseBranch, in: repoPath)
            statusMessage = "Updating \(selectedBranch) from \(tip)…"
            try await git.merge(source: tip, into: selectedBranch, in: repoPath)
            await reloadSnapshot(resetScope: true, fetchFirst: false)
            statusMessage = "Updated \(selectedBranch) with \(tip)."
            isUpdatingFromCompare = false
            // Clear the success toast shortly after.
            let message = statusMessage
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if statusMessage == message {
                    statusMessage = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            isUpdatingFromCompare = false
        }
    }

    func reloadSnapshot(resetScope: Bool = true, fetchFirst: Bool = false) async {
        guard let repoPath else { return }
        guard !selectedBranch.isEmpty, !baseBranch.isEmpty else {
            snapshot = nil
            return
        }

        loadTask?.cancel()
        let branch = selectedBranch
        let base = baseBranch
        isLoading = true
        errorMessage = nil
        if fetchFirst {
            statusMessage = "Fetching…"
        }
        persistMemory()

        loadTask = Task {
            do {
                if fetchFirst {
                    do {
                        try await git.fetchRemotes(in: repoPath)
                    } catch {
                        // Still reload local state; surface fetch failure.
                        guard !Task.isCancelled else { return }
                        errorMessage = "Fetch failed: \(error.localizedDescription)"
                    }
                    let listed = (try? await git.listBranches(in: repoPath)) ?? []
                    if !listed.isEmpty {
                        branches = listed
                    }
                }

                let snap = try await git.loadSnapshot(repo: repoPath, branch: branch, baseBranch: base)
                guard !Task.isCancelled else { return }
                snapshot = snap
                selectedAuthors = selectedAuthors.filter { author in
                    snap.commits.contains { $0.authorName == author }
                }
                if resetScope {
                    changeScope = .combined
                } else if case .commit(let hash) = changeScope,
                          !snap.commits.contains(where: { $0.hash == hash }) {
                    changeScope = .combined
                }
                clearInspectorCache()
                isLoading = false
                if fetchFirst, errorMessage == nil {
                    statusMessage = nil
                } else if !fetchFirst {
                    statusMessage = nil
                }
                async let worktreesReload: Void = reloadWorktrees()
                await reloadWorkingTree()
                await worktreesReload
                // reloadWorkingTree refreshes visible files for combined/staged/unstaged.
                if case .commit = changeScope {
                    await reloadVisibleFiles()
                }
                notifyStateChange()
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                snapshot = nil
                visibleFiles = []
                clearFileInspector()
                errorMessage = error.localizedDescription
                statusMessage = nil
                isLoading = false
            }
        }

        // Wait for the load task so restore can apply post-load selections.
        await loadTask?.value
    }

    func selectFile(_ file: ChangedFile) {
        // Keep searchFocusTarget as-is so ⌘F still targets the column the user
        // was interacting with (files filter vs inspector content).
        if case .fileLog = inspectorMode {
            closeFileLog()
        }
        let alreadySelected = selectedFileID == file.id
        selectedFileID = file.id
        notifyStateChange()
        if alreadySelected, !(beforeContents == nil && afterContents == nil && fileDiff.isEmpty) {
            return
        }
        Task { await loadFileInspector(for: file) }
    }

    func openFileLog(for file: ChangedFile) {
        selectedFileID = file.id
        inspectorMode = .fileLog(path: file.path)
        selectedFileLogID = nil
        fileLogDiff = ""
        fileLogContainingBranches = []
        fileLogError = nil
        Task { await loadFileLog(path: file.path) }
    }

    func closeFileLog() {
        fileLogTask?.cancel()
        fileLogDiffTask?.cancel()
        inspectorMode = .file
        fileLogEntries = []
        selectedFileLogID = nil
        fileLogDiff = ""
        fileLogContainingBranches = []
        fileLogError = nil
        isLoadingFileLog = false
        isLoadingFileLogDiff = false
    }

    func selectFileLogEntry(_ entry: FileLogEntry) {
        selectedFileLogID = entry.hash
        Task { await loadFileLogDiff(for: entry) }
    }

    func setSidePaneMode(_ mode: SidePaneMode) {
        sidePaneMode = mode
        showHistory = true
        if mode == .pullRequests {
            Task { await loadPullRequests() }
        }
        notifyStateChange()
    }

    func setPullRequestFilter(_ state: PullRequestState) {
        pullRequestFilter = state
        Task { await loadPullRequests() }
    }

    func selectPullRequest(_ pr: PullRequestSummary) {
        selectedPullRequestID = pr.number
        // Point Branch/Compare at the PR refs when those branches exist locally.
        if branches.contains(pr.baseRefName) {
            baseBranch = pr.baseRefName
        }
        if branches.contains(pr.headRefName) {
            selectedBranch = pr.headRefName
            persistMemory()
            clearInspectorCache()
            notifyStateChange()
            Task { await reloadSnapshot(resetScope: true) }
        } else {
            statusMessage = "PR #\(pr.number) head “\(pr.headRefName)” is not a local branch"
            notifyStateChange()
        }
    }

    func openPullRequestInBrowser(_ pr: PullRequestSummary) {
        guard let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }

    func loadPullRequests() async {
        guard let repoPath else { return }
        pullRequestTask?.cancel()
        isLoadingPullRequests = true
        pullRequestError = nil
        let state = pullRequestFilter

        pullRequestTask = Task {
            do {
                let list = try await github.listPullRequests(in: repoPath, state: state)
                guard !Task.isCancelled else { return }
                pullRequests = list
                let authors = Set(list.map(\.authorLogin))
                selectedPullRequestAuthors = selectedPullRequestAuthors.intersection(authors)
                if let selected = selectedPullRequestID, !list.contains(where: { $0.number == selected }) {
                    selectedPullRequestID = nil
                }
                isLoadingPullRequests = false
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                pullRequests = []
                pullRequestError = error.localizedDescription
                isLoadingPullRequests = false
            }
        }
        await pullRequestTask?.value
    }

    private func loadFileLog(path: String) async {
        guard let repoPath else { return }
        fileLogTask?.cancel()
        isLoadingFileLog = true
        fileLogError = nil

        fileLogTask = Task {
            do {
                let entries = try await git.fileHistory(in: repoPath, path: path)
                guard !Task.isCancelled else { return }
                fileLogEntries = entries
                isLoadingFileLog = false
                if let first = entries.first {
                    selectedFileLogID = first.hash
                    await loadFileLogDiff(for: first)
                } else {
                    fileLogDiff = ""
                    fileLogContainingBranches = []
                }
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                fileLogEntries = []
                fileLogError = error.localizedDescription
                isLoadingFileLog = false
            }
        }
        await fileLogTask?.value
    }

    private func loadFileLogDiff(for entry: FileLogEntry) async {
        guard let repoPath else { return }
        guard case .fileLog(let path) = inspectorMode else { return }
        fileLogDiffTask?.cancel()
        isLoadingFileLogDiff = true

        fileLogDiffTask = Task {
            do {
                async let diffTask = git.commitFileDiff(
                    in: repoPath,
                    commit: entry.hash,
                    path: path,
                    oldPath: nil
                )
                async let branchesTask = git.branchesContaining(in: repoPath, commit: entry.hash)
                let (diff, branches) = try await (diffTask, branchesTask)
                guard !Task.isCancelled, selectedFileLogID == entry.hash else { return }
                fileLogDiff = diff.isEmpty ? "(No textual diff for this path in \(entry.shortHash).)" : diff
                fileLogContainingBranches = branches
                isLoadingFileLogDiff = false
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled, selectedFileLogID == entry.hash else { return }
                fileLogDiff = error.localizedDescription
                fileLogContainingBranches = []
                isLoadingFileLogDiff = false
            }
        }
        await fileLogDiffTask?.value
    }

    func preferFileSearch() {
        searchFocusTarget = .fileFilter
    }

    func preferContentSearch() {
        searchFocusTarget = .content
    }

    func activateFindShortcut() {
        // If the files column is hidden, always search content.
        if !showFiles {
            searchFocusTarget = .content
        }
        searchFocusNonce &+= 1
    }

    func reloadVisibleFiles() async {
        guard let snapshot else {
            // Local-only scopes can still show working tree files without a branch snapshot.
            if changeScope == .staged || changeScope == .unstaged {
                let files = (changeScope == .staged ? stagedWorkingTreeFiles : unstagedWorkingTreeFiles)
                    .map(\.asChangedFile)
                visibleFiles = files
                selectedFileID = files.first?.id
                if let file = files.first {
                    await loadFileInspector(for: file)
                } else {
                    clearFileInspector()
                }
            } else {
                visibleFiles = []
            }
            return
        }

        scopeTask?.cancel()
        scopeTask = Task {
            do {
                let files: [ChangedFile]
                switch changeScope {
                case .combined:
                    if includeLocalChanges {
                        files = Self.mergeBranchAndLocalFiles(
                            branchFiles: snapshot.files,
                            localFiles: workingTreeFiles
                        )
                    } else {
                        files = snapshot.files
                    }
                case .commit(let hash):
                    files = try await git.commitChangedFiles(in: snapshot.repoPath, commit: hash)
                case .staged:
                    files = stagedWorkingTreeFiles.map(\.asChangedFile)
                case .unstaged:
                    files = unstagedWorkingTreeFiles.map(\.asChangedFile)
                }
                guard !Task.isCancelled else { return }
                let previousSelection = selectedFileID
                let listChanged = visibleFiles != files
                visibleFiles = files
                if let current = previousSelection, files.contains(where: { $0.id == current }) {
                    selectedFileID = current
                    // Only reload inspector when the file set or scope content likely changed.
                    if listChanged {
                        if let file = files.first(where: { $0.id == current }) {
                            await loadFileInspector(for: file)
                        }
                    }
                } else {
                    selectedFileID = files.first?.id
                    if let file = files.first {
                        await loadFileInspector(for: file)
                    } else {
                        clearFileInspector()
                    }
                }
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                visibleFiles = []
                clearFileInspector()
                errorMessage = error.localizedDescription
            }
        }
        await scopeTask?.value
    }

    private static func mergeBranchAndLocalFiles(
        branchFiles: [ChangedFile],
        localFiles: [WorkingTreeFile]
    ) -> [ChangedFile] {
        var byPath: [String: ChangedFile] = [:]
        for file in branchFiles {
            byPath[file.path] = file
        }
        for local in localFiles {
            if let existing = byPath[local.path] {
                byPath[local.path] = ChangedFile(
                    status: local.status == .unknown ? existing.status : local.status,
                    path: local.path,
                    oldPath: local.oldPath ?? existing.oldPath,
                    additions: max(existing.additions, local.additions),
                    deletions: max(existing.deletions, local.deletions)
                )
            } else {
                byPath[local.path] = local.asChangedFile
            }
        }
        return byPath.values.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func clearFileInspector() {
        fileDiff = ""
        beforeContents = nil
        afterContents = nil
        isLoadingFile = false
    }

    private func clearInspectorCache() {
        inspectorCache.removeAll(keepingCapacity: true)
        HighlightRenderCache.clear()
    }

    private func cacheKey(for file: ChangedFile, snapshot: BranchSnapshot) -> String {
        let localMarker = (includeLocalChanges && workingTreeFiles.contains(where: { $0.path == file.path }))
            ? "local"
            : "clean"
        return [
            snapshot.repoPath.path,
            snapshot.branch,
            snapshot.baseBranch,
            snapshot.mergeBase,
            changeScope.cacheKeyPart,
            includeLocalChanges ? "inclocal" : "nolocal",
            localMarker,
            file.path,
            file.oldPath ?? "",
        ].joined(separator: "|")
    }

    private func applyPayload(_ payload: FileInspectorPayload) {
        fileDiff = payload.diff
        beforeContents = payload.before
        afterContents = payload.after
        beforeLabel = payload.beforeLabel
        afterLabel = payload.afterLabel
        isLoadingFile = false
    }

    private func storeCache(key: String, payload: FileInspectorPayload) {
        inspectorCache[key] = payload
        if inspectorCache.count > cacheLimit {
            // Drop arbitrary oldest-ish entries by removing a prefix of keys.
            let overflow = inspectorCache.count - cacheLimit
            for key in inspectorCache.keys.prefix(overflow) {
                inspectorCache.removeValue(forKey: key)
            }
        }
    }

    private func loadFileInspector(for file: ChangedFile) async {
        guard let repoPath else { return }
        let key: String
        if let snapshot {
            key = cacheKey(for: file, snapshot: snapshot)
        } else {
            key = [repoPath.path, changeScope.cacheKeyPart, file.path, file.oldPath ?? ""].joined(separator: "|")
        }

        if let cached = inspectorCache[key] {
            applyPayload(cached)
            return
        }

        fileTask?.cancel()
        isLoadingFile = true

        let beforePath = file.oldPath ?? file.path
        let afterPath = file.path
        let scope = changeScope
        let snap = snapshot
        let localMatch = workingTreeFiles.first { $0.path == file.path }

        fileTask = Task {
            do {
                let diff: String
                let before: String?
                let after: String?
                let beforeName: String
                let afterName: String

                switch scope {
                case .combined:
                    if let snap {
                        let hasLocal = includeLocalChanges && localMatch != nil
                        if hasLocal {
                            async let diffTask = git.worktreeDiff(
                                in: repoPath,
                                from: snap.mergeBase,
                                path: afterPath,
                                oldPath: file.oldPath
                            )
                            async let beforeTask = git.fileContents(in: repoPath, revision: snap.mergeBase, path: beforePath)
                            async let afterTask = git.workingTreeFileContents(in: repoPath, path: afterPath)
                            (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                            beforeName = "\(snap.baseBranch) @ \(snap.mergeBaseShort)"
                            afterName = "Working tree"
                        } else {
                            async let diffTask = git.fileDiff(
                                in: repoPath,
                                from: snap.mergeBase,
                                to: snap.branch,
                                path: file.path,
                                oldPath: file.oldPath
                            )
                            async let beforeTask = git.fileContents(in: repoPath, revision: snap.mergeBase, path: beforePath)
                            async let afterTask = git.fileContents(in: repoPath, revision: snap.branch, path: afterPath)
                            (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                            beforeName = "\(snap.baseBranch) @ \(snap.mergeBaseShort)"
                            afterName = snap.branch
                        }
                    } else {
                        throw GitError.commandFailed("No branch snapshot loaded.")
                    }
                case .commit(let hash):
                    guard let snap else { throw GitError.commandFailed("No branch snapshot loaded.") }
                    let short = snap.commits.first(where: { $0.hash == hash })?.shortHash ?? String(hash.prefix(8))
                    let parent = "\(hash)^"
                    async let diffTask = git.commitFileDiff(
                        in: repoPath,
                        commit: hash,
                        path: file.path,
                        oldPath: file.oldPath
                    )
                    async let beforeTask = git.fileContents(in: repoPath, revision: parent, path: beforePath)
                    async let afterTask = git.fileContents(in: repoPath, revision: hash, path: afterPath)
                    (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                    beforeName = "parent of \(short)"
                    afterName = short
                case .staged:
                    async let diffTask = git.stagedDiff(in: repoPath, path: afterPath, oldPath: file.oldPath)
                    async let beforeTask = git.fileContents(in: repoPath, revision: "HEAD", path: beforePath)
                    async let afterTask = git.indexFileContents(in: repoPath, path: afterPath)
                    (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                    beforeName = "HEAD"
                    afterName = "Index (staged)"
                case .unstaged:
                    let unstaged = try await git.unstagedDiff(in: repoPath, path: afterPath, oldPath: file.oldPath)
                    let worktree = try await git.workingTreeFileContents(in: repoPath, path: afterPath)
                    let index: String?
                    if let fromIndex = try await git.indexFileContents(in: repoPath, path: beforePath) {
                        index = fromIndex
                    } else {
                        index = try await git.fileContents(in: repoPath, revision: "HEAD", path: beforePath)
                    }
                    if unstaged.isEmpty, file.status == .added, let worktree, !worktree.isEmpty {
                        diff = "--- /dev/null\n+++ b/\(afterPath)\n@@ untracked @@\n"
                        before = nil
                        after = worktree
                        beforeName = "(new file)"
                        afterName = "Working tree"
                    } else {
                        diff = unstaged
                        before = index
                        after = worktree
                        beforeName = "Index / HEAD"
                        afterName = "Working tree"
                    }
                }

                guard !Task.isCancelled else { return }
                let payload = FileInspectorPayload(
                    diff: diff.isEmpty ? "(No textual diff — binary or empty change.)" : diff,
                    before: before,
                    after: after,
                    beforeLabel: beforeName,
                    afterLabel: afterName
                )
                storeCache(key: key, payload: payload)
                if selectedFileID == file.id {
                    applyPayload(payload)
                }
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                if selectedFileID == file.id {
                    fileDiff = error.localizedDescription
                    beforeContents = nil
                    afterContents = nil
                    isLoadingFile = false
                }
            }
        }
    }

    private func persistMemory() {
        guard let repoPath, !selectedBranch.isEmpty else { return }
        RepoMemory.save(repo: repoPath, branch: selectedBranch, base: baseBranch)
    }
}

enum RecentRepos {
    private static let key = "BranchLens.recentRepos"
    private static let limit = 8

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    static func remember(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        let path = url.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > limit {
            paths = Array(paths.prefix(limit))
        }
        UserDefaults.standard.set(paths, forKey: key)
    }
}

enum RepoMemory {
    private static let key = "BranchLens.repoBranchMemory"

    struct Entry: Codable {
        var branch: String
        var base: String
    }

    static func load(for repo: URL) -> Entry? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return nil
        }
        return map[repo.path]
    }

    static func save(repo: URL, branch: String, base: String) {
        var map: [String: Entry] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            map = decoded
        }
        map[repo.path] = Entry(branch: branch, base: base)
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
