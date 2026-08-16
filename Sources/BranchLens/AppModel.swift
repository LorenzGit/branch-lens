import AppKit
import BranchLensCore
import Foundation
import SwiftUI

struct PendingEditDiscard: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onDiscard: () -> Void
}

private struct EditFileStamp: Equatable {
    var mtime: TimeInterval
    var size: UInt64
}

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
    case crossFile
    case content
}

enum CrossFileSearchMode: String, CaseIterable, Identifiable {
    case fullSource = "Full Source"
    case modifications = "Modifications"

    var id: String { rawValue }
}

enum SidePaneMode: String, CaseIterable, Identifiable {
    case history = "History"
    case pullRequests = "PRs"

    var id: String { rawValue }
}

enum HistoryBrowseMode: String, CaseIterable, Identifiable {
    /// Commits on BRANCH since COMPARE (default inspector mode).
    case current = "Current"
    /// Full chronological log of BRANCH (read-only browsing).
    case all = "All"

    var id: String { rawValue }
}

enum InspectorMode: Equatable {
    case file
    case fileLog(path: String)
}

struct MergedIntoCompareInfo: Equatable {
    enum Kind: Equatable {
        /// Merged PR whose head was this BRANCH.
        case mergedPR
        /// BRANCH tip is identical to COMPARE.
        case inSync
        /// BRANCH is contained in COMPARE, but no merged PR for this head.
        case contained
    }

    var kind: Kind
    var compareLabel: String
    var commits: [GitCommit]
    var pullRequest: CommitPullRequestLink?
}

struct FileInspectorPayload: Sendable {
    var diff: String
    var before: String?
    var after: String?
    var beforeImageData: Data? = nil
    var afterImageData: Data? = nil
    var beforeLabel: String
    var afterLabel: String

    var hasImagePreview: Bool {
        beforeImageData != nil || afterImageData != nil
    }
}

@MainActor
final class RepoSession: ObservableObject, Identifiable {
    let id: UUID
    var onStateChange: (() -> Void)?

    @Published var repoPath: URL?
    @Published var branchRecords: [GitBranch] = []
    var branches: [String] { branchRecords.map(\.name) }
    var branchTipDates: [String: Date] {
        Dictionary(uniqueKeysWithValues: branchRecords.map { ($0.name, $0.tipDate) })
    }
    @Published var selectedBranch: String = ""
    /// Branch currently checked out in this worktree (`git branch --show-current`).
    @Published var checkedOutBranch: String?
    @Published var baseBranch: String = ""
    @Published var snapshot: BranchSnapshot?
    @Published var changeScope: ChangeScope = .combined
    @Published var historyBrowseMode: HistoryBrowseMode = .current
    @Published var chronologicalCommits: [GitCommit] = []
    @Published var isLoadingChronologicalCommits = false
    @Published var hasMoreChronologicalCommits = false
    @Published var selectedFileID: String?
    /// Multi-select set (⌘/⇧ click). Primary/last focus stays in `selectedFileID`.
    @Published var selectedFileIDs: Set<String> = []
    @Published var fileViewMode: FileViewMode = .diff
    /// Render Markdown instead of raw source when the selected file is `.md`.
    @Published var showMarkdownPreview = false
    /// Inline editing of the working-tree file in the inspector.
    @Published var isEditingFile = false
    @Published var editDraft = ""
    /// Contents when the edit session started (for dirty detection).
    private var editBaseline = ""
    @Published var editCanUndo = false
    @Published var editCanRedo = false
    @Published var isSavingEdit = false
    /// Remount key so each edit session starts with a clean undo stack.
    @Published var editSessionNonce = 0
    /// Asked when leaving edit mode with unsaved changes.
    @Published var pendingEditDiscard: PendingEditDiscard?
    /// File on disk changed while this edit session is open.
    @Published var editExternallyChanged = false
    private var editWatchedURL: URL?
    private var editKnownStamp: EditFileStamp?
    private var editWatchTask: Task<Void, Never>?
    private var editActiveObserver: NSObjectProtocol?
    @Published var visibleFiles: [ChangedFile] = []
    @Published var fileDiff: String = ""
    @Published var beforeContents: String?
    @Published var afterContents: String?
    @Published var beforeImageData: Data?
    @Published var afterImageData: Data?
    @Published var beforeLabel: String = "Before"
    @Published var afterLabel: String = "After"
    @Published var selectedAuthors: Set<String> = []
    @Published var fileNameQuery: String = ""
    @Published var contentQuery: String = ""
    /// Search string across all changed files (filters the Files list).
    @Published var crossFileQuery: String = ""
    @Published var crossFileSearchMode: CrossFileSearchMode = .modifications
    /// path → match count for the active cross-file query.
    @Published var crossFileMatchCounts: [String: Int] = [:]
    @Published var isSearchingCrossFile = false
    /// Find-in-files tool sheet (not always visible in the Files pane).
    @Published var isCrossFileSearchPresented = false
    /// Commit-staged sheet (from History → Staged card).
    @Published var isCommitSheetPresented = false
    @Published var commitMessageDraft = ""
    @Published var commitShouldPush = false
    @Published var isCommitting = false
    @Published var isPushing = false
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
    /// Bumped after fetch/reload so inspector views remount with fresh content.
    @Published var contentRefreshNonce: Int = 0

    // Working tree (local staged / unstaged)
    @Published var workingTreeFiles: [WorkingTreeFile] = []
    /// Net merge-base → worktree files when “Include local changes” is on (cancels overlapping +/-).
    @Published private(set) var allChangesWithLocalFiles: [ChangedFile] = []
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
    /// Commit SHA → associated PR for History cards.
    @Published var commitPullRequests: [String: CommitPullRequestLink] = [:]
    /// SHAs already queried (including commits with no PR).
    private var commitPRResolved: Set<String> = []
    /// Commit SHA → files / +/- for History cards.
    @Published var commitChangeStats: [String: CommitChangeStats] = [:]
    private var commitStatsResolved: Set<String> = []
    /// When BRANCH has no unique commits vs COMPARE because it was already merged.
    @Published var mergedIntoCompare: MergedIntoCompareInfo?

    private let git = GitService()
    private let github = GitHubService()
    private var loadTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var scopeTask: Task<Void, Never>?
    private var workingTreeTask: Task<Void, Never>?
    private var fileLogTask: Task<Void, Never>?
    private var fileLogDiffTask: Task<Void, Never>?
    private var pullRequestTask: Task<Void, Never>?
    private var commitPRTask: Task<Void, Never>?
    private var mergedIntoCompareTask: Task<Void, Never>?
    private var crossFileSearchTask: Task<Void, Never>?
    private var inspectorCache: [String: FileInspectorPayload] = [:]
    private let cacheLimit = 96
    private let commitPRLookupLimit = 60
    /// Anchor for Shift+Click range selection.
    private var selectionAnchorID: String?
    /// Last fetch+reload (auto or manual). Auto-refresh is skipped within the cooldown.
    private var lastFetchRefreshAt: Date?
    private static let autoFetchCooldown: TimeInterval = 3 * 60

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
        if let id = state.selectedFileID {
            selectedFileIDs = [id]
            selectionAnchorID = id
        } else {
            selectedFileIDs = []
            selectionAnchorID = nil
        }
        if includeLocalChanges {
            await reloadWorkingTree()
        }
        await reloadVisibleFiles()
        notifyStateChange()
    }

    var selectedFile: ChangedFile? {
        guard let selectedFileID else { return nil }
        return visibleFiles.first { $0.id == selectedFileID }
            ?? nameFilteredFiles.first { $0.id == selectedFileID }
    }

    var hasMultiFileSelection: Bool {
        selectedFileIDs.count > 1
    }

    var selectedFiles: [ChangedFile] {
        let order = nameFilteredFiles
        return order.filter { selectedFileIDs.contains($0.id) }
    }

    var selectedFilesStagable: [ChangedFile] {
        selectedFiles.filter(isUnstaged)
    }

    var selectedFilesUnstagable: [ChangedFile] {
        selectedFiles.filter(isStaged)
    }

    var stagedWorkingTreeFiles: [WorkingTreeFile] {
        workingTreeFiles.filter { $0.area == .staged }
    }

    var unstagedWorkingTreeFiles: [WorkingTreeFile] {
        workingTreeFiles.filter { $0.area == .unstaged }
    }

    /// Unique local paths with staged and/or unstaged edits.
    var localChangeFileCount: Int {
        Set(workingTreeFiles.map(\.path)).count
    }

    var localChangeAdditions: Int {
        workingTreeFiles.reduce(0) { $0 + $1.additions }
    }

    var allChangesDisplayedAdditions: Int {
        if includeLocalChanges {
            return allChangesWithLocalFiles.reduce(0) { $0 + $1.additions }
        }
        return snapshot?.totalAdditions ?? 0
    }

    var allChangesDisplayedDeletions: Int {
        if includeLocalChanges {
            return allChangesWithLocalFiles.reduce(0) { $0 + $1.deletions }
        }
        return snapshot?.totalDeletions ?? 0
    }

    var allChangesDisplayedFileCount: Int {
        if includeLocalChanges {
            return allChangesWithLocalFiles.count
        }
        return snapshot?.files.count ?? 0
    }

    var localChangeDeletions: Int {
        workingTreeFiles.reduce(0) { $0 + $1.deletions }
    }

    var hasLocalChanges: Bool {
        !workingTreeFiles.isEmpty
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

    /// Commits already on the fresh COMPARE tip that only appear because local COMPARE is stale.
    var staleInheritedCommitHashes: Set<String> {
        guard let snapshot else { return [] }
        let inherited = snapshot.staleCompareInheritedCommitCount
        guard inherited > 0 else { return [] }
        return Set(snapshot.commits.suffix(inherited).map(\.hash))
    }

    /// Current-mode History: unique branch commits only (hide stale COMPARE leftovers).
    var uniqueFilteredCommits: [GitCommit] {
        let inherited = staleInheritedCommitHashes
        guard !inherited.isEmpty else { return filteredCommits }
        return filteredCommits.filter { !inherited.contains($0.hash) }
    }

    /// Commits shown in the History list for the active browse mode.
    var displayedHistoryCommits: [GitCommit] {
        let source: [GitCommit]
        switch historyBrowseMode {
        case .current:
            source = snapshot?.commits ?? []
        case .all:
            source = chronologicalCommits
        }
        if selectedAuthors.isEmpty { return source }
        return source.filter { selectedAuthors.contains($0.authorName) }
    }

    /// Staging actions only apply while reviewing Current (COMPARE…BRANCH) work, not full history.
    var showsStagingActions: Bool {
        historyBrowseMode == .current
    }

    private static let chronologicalBatchSize = 200

    /// Commits shown under the “fully merged” History banner (author filter applied).
    var filteredMergedCommits: [GitCommit] {
        guard let merged = mergedIntoCompare else { return [] }
        if selectedAuthors.isEmpty { return merged.commits }
        return merged.commits.filter { selectedAuthors.contains($0.authorName) }
    }

    /// Name filter only (used for Shift+Click range order and selection lists).
    var nameFilteredFiles: [ChangedFile] {
        let query = fileNameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleFiles }
        return visibleFiles.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    /// Files shown in the Files pane (name filter + optional cross-file content search).
    var filteredFiles: [ChangedFile] {
        let named = nameFilteredFiles
        let cross = crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cross.isEmpty else { return named }
        // While the first search is in flight, keep showing the name-filtered list.
        if crossFileMatchCounts.isEmpty, isSearchingCrossFile { return named }
        return named.filter { crossFileMatchCounts[$0.id] != nil }
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

    /// Stable path list for folder-expansion onChange (ignores add/del count flicker).
    var fileTreePathSignature: String {
        filteredFiles.map(\.path).sorted().joined(separator: "\n")
    }

    /// Commit currently driving the Changed files scope (selected commit, or tip when combined).
    var activeScopeCommit: GitCommit? {
        switch changeScope {
        case .commit(let hash):
            return snapshot?.commits.first(where: { $0.hash == hash })
                ?? filteredCommits.first(where: { $0.hash == hash })
                ?? chronologicalCommits.first(where: { $0.hash == hash })
                ?? mergedIntoCompare?.commits.first(where: { $0.hash == hash })
        case .combined:
            return filteredCommits.first
                ?? snapshot?.commits.first
                ?? mergedIntoCompare?.commits.first
        case .staged, .unstaged:
            return nil
        }
    }

    func setHistoryBrowseMode(_ mode: HistoryBrowseMode) {
        guard historyBrowseMode != mode else { return }
        historyBrowseMode = mode
        notifyStateChange()
        Task { await applyHistoryBrowseModeChange() }
    }

    /// Keep Changed files / inspector aligned with Current vs All History.
    private func applyHistoryBrowseModeChange() async {
        switch historyBrowseMode {
        case .all:
            await reloadChronologicalCommits(reset: true)
            if case .commit(let hash) = changeScope,
               chronologicalCommits.contains(where: { $0.hash == hash }) {
                await reloadVisibleFiles(forceInspectorReload: true)
            } else if let tip = chronologicalCommits.first {
                changeScope = .commit(tip.hash)
                notifyStateChange()
                await reloadVisibleFiles(forceInspectorReload: true)
            } else {
                changeScope = .combined
                notifyStateChange()
                await reloadVisibleFiles(forceInspectorReload: true)
            }
        case .current:
            if case .commit(let hash) = changeScope,
               snapshot?.commits.contains(where: { $0.hash == hash }) == true {
                await reloadVisibleFiles(forceInspectorReload: true)
            } else {
                changeScope = .combined
                notifyStateChange()
                await reloadVisibleFiles(forceInspectorReload: true)
            }
        }
        contentRefreshNonce &+= 1
        notifyStateChange()
    }

    func reloadChronologicalCommits(reset: Bool = true) async {
        guard let repoPath, !selectedBranch.isEmpty else {
            chronologicalCommits = []
            hasMoreChronologicalCommits = false
            return
        }
        if isLoadingChronologicalCommits { return }
        if !reset, !hasMoreChronologicalCommits { return }

        isLoadingChronologicalCommits = true
        let skip = reset ? 0 : chronologicalCommits.count
        do {
            let batch = try await git.listCommitsChronological(
                in: repoPath,
                branch: selectedBranch,
                limit: Self.chronologicalBatchSize,
                skip: skip
            )
            if reset {
                chronologicalCommits = batch
            } else {
                // Avoid rare overlaps if the tip moved while scrolling.
                let existing = Set(chronologicalCommits.map(\.hash))
                chronologicalCommits.append(contentsOf: batch.filter { !existing.contains($0.hash) })
            }
            hasMoreChronologicalCommits = batch.count >= Self.chronologicalBatchSize
        } catch {
            if reset {
                chronologicalCommits = []
                hasMoreChronologicalCommits = false
            }
            if historyBrowseMode == .all {
                errorMessage = error.localizedDescription
            }
        }
        isLoadingChronologicalCommits = false
        notifyStateChange()
    }

    /// Infinite-scroll helper: load the next batch when a near-end row appears.
    func loadMoreChronologicalCommitsIfNeeded(near commit: GitCommit) async {
        guard historyBrowseMode == .all, hasMoreChronologicalCommits, !isLoadingChronologicalCommits else { return }
        guard let index = chronologicalCommits.firstIndex(where: { $0.hash == commit.hash }) else { return }
        let threshold = max(chronologicalCommits.count - 30, 0)
        guard index >= threshold else { return }
        await reloadChronologicalCommits(reset: false)
    }

    /// Lazy PR badge fetch for a single visible History card.
    func ensureCommitPullRequest(for commit: GitCommit) async {
        await loadCommitPullRequests(for: [commit])
    }

    func changeStats(forCommitHash hash: String) -> CommitChangeStats? {
        commitChangeStats[hash]
    }

    /// Lazy files/+/- fetch for a visible History card.
    func ensureCommitChangeStats(for commit: GitCommit) async {
        guard let repoPath else { return }
        guard !commitStatsResolved.contains(commit.hash) else { return }
        commitStatsResolved.insert(commit.hash)
        do {
            let stats = try await git.commitChangeStats(in: repoPath, commit: commit.hash)
            commitChangeStats[commit.hash] = stats
        } catch {
            // Leave unresolved visually; don't retry forever on hard failures.
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

    /// Line numbers from the current unified diff for Compare pane tinting.
    /// Cached — parsing a large PR diff on every SwiftUI body eval was a hang risk.
    private var cachedCompareChangedLineNumbers: (deleted: Set<Int>, added: Set<Int>) = ([], [])
    private var cachedCompareChangedLineNumbersDiffID: Int = 0

    var compareChangedLineNumbers: (deleted: Set<Int>, added: Set<Int>) {
        cachedCompareChangedLineNumbers
    }
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
            branchRecords = listed
            let names = listed.map(\.name)
            let memory = RepoMemory.load(for: root)
            let current = try await git.currentBranch(in: root)
            checkedOutBranch = current
            let detectedBase = try await git.detectBaseBranch(in: root, branches: names) ?? ""

            if let preferredBranch, names.contains(preferredBranch) {
                selectedBranch = preferredBranch
            } else if let remembered = memory?.branch, names.contains(remembered) {
                selectedBranch = remembered
            } else if let current, names.contains(current), current != detectedBase {
                selectedBranch = current
            } else if let other = names.first(where: { $0 != detectedBase }) {
                selectedBranch = other
            } else {
                selectedBranch = names.first ?? ""
            }

            if let preferredBase, names.contains(preferredBase) {
                baseBranch = preferredBase
            } else if let rememberedBase = memory?.base, names.contains(rememberedBase) {
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
                commitPullRequests = [:]
                commitPRResolved = []
                commitChangeStats = [:]
                commitStatsResolved = []
                mergedIntoCompare = nil
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
        requestLeaveEditingIfNeeded {
            self.changeScope = .combined
            self.notifyStateChange()
            Task { await self.reloadVisibleFiles() }
        }
    }

    func selectStaged() {
        requestLeaveEditingIfNeeded {
            self.includeLocalChanges = true
            self.changeScope = .staged
            self.notifyStateChange()
            Task { await self.reloadVisibleFiles() }
        }
    }

    func selectUnstaged() {
        requestLeaveEditingIfNeeded {
            self.includeLocalChanges = true
            self.changeScope = .unstaged
            self.notifyStateChange()
            Task { await self.reloadVisibleFiles() }
        }
    }

    func selectCommit(_ commit: GitCommit) {
        requestLeaveEditingIfNeeded {
            self.changeScope = .commit(commit.hash)
            self.notifyStateChange()
            Task { await self.reloadVisibleFiles() }
        }
    }

    func setIncludeLocalChanges(_ enabled: Bool) {
        includeLocalChanges = enabled
        if !enabled, changeScope == .staged || changeScope == .unstaged {
            changeScope = .combined
        }
        if !enabled {
            allChangesWithLocalFiles = []
        }
        notifyStateChange()
        Task {
            if enabled {
                await reloadWorkingTree()
            }
            await reloadVisibleFiles()
        }
    }

    /// Toolbar refresh: fetch remotes, then reload History, Changed files, and inspector content.
    /// - Parameter force: When true (manual button), always runs and resets the auto-fetch cooldown.
    ///   When false (window activate / tab switch), skips if a fetch ran within the last 3 minutes.
    func refresh(force: Bool = true) async {
        guard repoPath != nil else { return }
        if !force {
            if let last = lastFetchRefreshAt,
               Date().timeIntervalSince(last) < Self.autoFetchCooldown {
                return
            }
        }
        // Claim the cooldown immediately so activate + tab-switch bursts coalesce.
        lastFetchRefreshAt = Date()

        await reloadSnapshot(resetScope: false, fetchFirst: true, refreshPanes: true)
        if sidePaneMode == .pullRequests {
            await loadPullRequests()
        }
        if case .fileLog(let path) = inspectorMode {
            await loadFileLog(path: path)
        }
    }

    /// Auto fetch+reload when the window becomes active or this tab is selected.
    func refreshIfStale() async {
        await refresh(force: false)
    }

    func isUnstaged(_ file: ChangedFile) -> Bool {
        guard showsStagingActions else { return false }
        if changeScope == .unstaged { return true }
        if changeScope == .staged { return false }
        return workingTreeFiles.contains { $0.path == file.path && $0.area == .unstaged }
    }

    func isStaged(_ file: ChangedFile) -> Bool {
        guard showsStagingActions else { return false }
        if changeScope == .staged { return true }
        if changeScope == .unstaged { return false }
        return workingTreeFiles.contains { $0.path == file.path && $0.area == .staged }
    }

    /// Preferred area for single-action UI (Unstaged wins when both exist).
    func stagingArea(for file: ChangedFile) -> WorkingTreeArea? {
        if isUnstaged(file) { return .unstaged }
        if isStaged(file) { return .staged }
        return nil
    }

    func stageFile(_ file: ChangedFile) async {
        guard let repoPath else { return }
        var paths = [file.path]
        if let old = file.oldPath, old != file.path { paths.append(old) }
        do {
            try await git.stagePaths(paths, in: repoPath)
            await refreshAfterStaging(preferSelecting: file.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstageFile(_ file: ChangedFile) async {
        guard let repoPath else { return }
        var paths = [file.path]
        if let old = file.oldPath, old != file.path { paths.append(old) }
        do {
            try await git.unstagePaths(paths, in: repoPath)
            await refreshAfterStaging(preferSelecting: file.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stageAllUnstaged() async {
        guard let repoPath else { return }
        let paths = Array(Set(unstagedWorkingTreeFiles.flatMap { file -> [String] in
            if let old = file.oldPath, old != file.path { return [file.path, old] }
            return [file.path]
        }))
        guard !paths.isEmpty else { return }
        do {
            try await git.stagePaths(paths, in: repoPath)
            await refreshAfterStaging(preferSelecting: selectedFile?.path ?? paths[0])
            statusMessage = "Staged \(paths.count) path\(paths.count == 1 ? "" : "s")."
            clearStatusEventually(statusMessage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstageAllStaged() async {
        guard let repoPath else { return }
        let paths = Array(Set(stagedWorkingTreeFiles.flatMap { file -> [String] in
            if let old = file.oldPath, old != file.path { return [file.path, old] }
            return [file.path]
        }))
        guard !paths.isEmpty else { return }
        do {
            try await git.unstagePaths(paths, in: repoPath)
            await refreshAfterStaging(preferSelecting: selectedFile?.path ?? paths[0])
            statusMessage = "Unstaged \(paths.count) path\(paths.count == 1 ? "" : "s")."
            clearStatusEventually(statusMessage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openCommitSheet() {
        guard !stagedWorkingTreeFiles.isEmpty else { return }
        commitMessageDraft = ""
        commitShouldPush = false
        errorMessage = nil
        isCommitSheetPresented = true
    }

    var unpushedCommitCount: Int {
        snapshot?.aheadOfRemote ?? 0
    }

    func pushBranch() async {
        guard let repoPath, !selectedBranch.isEmpty else { return }
        isPushing = true
        statusMessage = "Pushing \(selectedBranch)…"
        do {
            try await git.pushCurrentBranch(in: repoPath, branch: selectedBranch)
            await reloadSnapshot(resetScope: false, fetchFirst: true, refreshPanes: false)
            statusMessage = "Pushed \(selectedBranch)."
            clearStatusEventually(statusMessage)
            notifyStateChange()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isPushing = false
    }

    func commitStaged(message: String, push: Bool) async {
        guard let repoPath else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Commit message cannot be empty."
            return
        }
        guard !stagedWorkingTreeFiles.isEmpty else {
            errorMessage = "Nothing staged to commit."
            return
        }

        isCommitting = true
        statusMessage = push ? "Committing and pushing…" : "Committing…"
        do {
            try await git.commit(message: trimmed, in: repoPath)
            if push {
                try await git.pushCurrentBranch(in: repoPath, branch: selectedBranch)
            }
            isCommitSheetPresented = false
            commitMessageDraft = ""
            commitShouldPush = false
            clearInspectorCache()
            await reloadWorkingTree(updateVisibleFiles: false)
            await reloadSnapshot(resetScope: false, fetchFirst: false, refreshPanes: true)
            if changeScope == .staged || changeScope == .unstaged || includeLocalChanges {
                await reloadVisibleFiles(forceInspectorReload: true)
            }
            contentRefreshNonce &+= 1
            statusMessage = push ? "Committed and pushed." : "Committed."
            clearStatusEventually(statusMessage)
            notifyStateChange()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isCommitting = false
    }

    func stageSelectedFiles() async {
        let files = selectedFilesStagable
        guard let repoPath, !files.isEmpty else { return }
        let paths = Array(Set(files.flatMap { file -> [String] in
            if let old = file.oldPath, old != file.path { return [file.path, old] }
            return [file.path]
        }))
        do {
            try await git.stagePaths(paths, in: repoPath)
            await refreshAfterStaging(preferSelecting: files[0].path)
            statusMessage = "Staged \(files.count) file\(files.count == 1 ? "" : "s")."
            clearStatusEventually(statusMessage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstageSelectedFiles() async {
        let files = selectedFilesUnstagable
        guard let repoPath, !files.isEmpty else { return }
        let paths = Array(Set(files.flatMap { file -> [String] in
            if let old = file.oldPath, old != file.path { return [file.path, old] }
            return [file.path]
        }))
        do {
            try await git.unstagePaths(paths, in: repoPath)
            await refreshAfterStaging(preferSelecting: files[0].path)
            statusMessage = "Unstaged \(files.count) file\(files.count == 1 ? "" : "s")."
            clearStatusEventually(statusMessage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stageHunk(_ hunk: DiffHunk, for file: ChangedFile) async {
        await applyHunk(hunk, for: file, reverse: false)
    }

    func unstageHunk(_ hunk: DiffHunk, for file: ChangedFile) async {
        await applyHunk(hunk, for: file, reverse: true)
    }

    private func applyHunk(_ hunk: DiffHunk, for file: ChangedFile, reverse: Bool) async {
        guard let repoPath else { return }
        if hunk.isSyntheticUntracked {
            // Synthetic untracked marker — stage the whole file instead.
            if !reverse {
                await stageFile(file)
            }
            return
        }
        guard let patch = DiffParser.patch(
            for: hunk,
            path: file.path,
            oldPath: file.oldPath,
            originalDiff: fileDiff
        ) else {
            errorMessage = "Could not build a patch for this hunk."
            return
        }
        do {
            try await git.applyPatchToIndex(patch, in: repoPath, reverse: reverse)
            await refreshAfterStaging(preferSelecting: file.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAfterStaging(preferSelecting path: String) async {
        clearInspectorCache()
        await reloadWorkingTree(updateVisibleFiles: false)
        // Keep the user in the same local scope when possible.
        await reloadVisibleFiles(forceInspectorReload: true)
        if !hasMultiFileSelection, let stillVisible = visibleFiles.first(where: { $0.path == path }) {
            selectedFileID = stillVisible.id
            selectedFileIDs = [stillVisible.id]
            selectionAnchorID = stillVisible.id
            await loadFileInspector(for: stillVisible)
        }
        contentRefreshNonce &+= 1
        notifyStateChange()
    }

    func reloadWorkingTree(updateVisibleFiles: Bool = true) async {
        guard let repoPath else {
            workingTreeFiles = []
            allChangesWithLocalFiles = []
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
                if includeLocalChanges {
                    await reloadAllChangesWithLocal()
                }
                // Avoid needless list reloads (they jump the Changed files scroller).
                // Callers that already rebuild panes (refresh / reloadSnapshot) pass false.
                let scopeNeedsLocal = changeScope == .staged
                    || changeScope == .unstaged
                    || (changeScope == .combined && includeLocalChanges)
                if updateVisibleFiles, scopeNeedsLocal, previous != files {
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

    /// Refresh net All-changes file list (merge-base → worktree).
    private func reloadAllChangesWithLocal() async {
        guard includeLocalChanges, let snap = snapshot else {
            allChangesWithLocalFiles = []
            return
        }
        do {
            allChangesWithLocalFiles = try await git.changedFilesToWorktree(
                in: snap.repoPath,
                from: snap.mergeBase
            )
        } catch is CancellationError {
            // ignore
        } catch {
            errorMessage = error.localizedDescription
        }
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

    /// Bring BRANCH up to date with COMPARE tip.
    /// When BRANCH == COMPARE (e.g. inspecting `main` vs `main`), fast-forward to the
    /// fresh remote tip instead of trying to merge a branch into itself.
    func updateFromCompare() async {
        guard let repoPath else { return }
        guard !selectedBranch.isEmpty, !baseBranch.isEmpty else { return }

        isUpdatingFromCompare = true
        errorMessage = nil
        statusMessage = "Updating \(selectedBranch) from \(baseBranch)…"

        do {
            // Prefer fresh remote tips before merging / fast-forwarding.
            try? await git.fetchRemotes(in: repoPath)
            let tip = await git.resolveFreshTip(for: baseBranch, in: repoPath)

            if selectedBranch == baseBranch {
                guard tip != selectedBranch else {
                    errorMessage = "No fresher tip than local \(selectedBranch)."
                    statusMessage = nil
                    isUpdatingFromCompare = false
                    return
                }
                statusMessage = "Fast-forwarding \(selectedBranch) to \(tip)…"
                try await git.fastForwardLocalBranch(selectedBranch, to: tip, in: repoPath)
                await reloadSnapshot(resetScope: true, fetchFirst: false)
                statusMessage = "Updated \(selectedBranch) to \(tip)."
            } else {
                statusMessage = "Updating \(selectedBranch) from \(tip)…"
                try await git.merge(source: tip, into: selectedBranch, in: repoPath)
                // Keep local COMPARE from staying stale after a successful update.
                if tip != baseBranch {
                    try? await git.fastForwardLocalBranch(baseBranch, to: tip, in: repoPath)
                }
                await reloadSnapshot(resetScope: true, fetchFirst: false)
                statusMessage = "Updated \(selectedBranch) with \(tip)."
            }
            isUpdatingFromCompare = false
            clearStatusEventually(statusMessage)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            isUpdatingFromCompare = false
        }
    }

    /// Fast-forward local COMPARE (e.g. stale `main`) to its fresh tip without changing BRANCH.
    func updateLocalCompare() async {
        guard let repoPath else { return }
        guard !baseBranch.isEmpty else { return }

        isUpdatingFromCompare = true
        errorMessage = nil
        statusMessage = "Updating local \(baseBranch)…"

        do {
            try? await git.fetchRemotes(in: repoPath)
            let tip = await git.resolveFreshTip(for: baseBranch, in: repoPath)
            guard tip != baseBranch else {
                statusMessage = nil
                isUpdatingFromCompare = false
                errorMessage = "No fresher tip than local \(baseBranch)."
                return
            }
            statusMessage = "Fast-forwarding \(baseBranch) to \(tip)…"
            try await git.fastForwardLocalBranch(baseBranch, to: tip, in: repoPath)
            await reloadSnapshot(resetScope: false, fetchFirst: false)
            statusMessage = "Updated local \(baseBranch) to \(tip)."
            isUpdatingFromCompare = false
            clearStatusEventually(statusMessage)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            isUpdatingFromCompare = false
        }
    }

    private func clearStatusEventually(_ message: String?) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if statusMessage == message {
                statusMessage = nil
            }
        }
    }

    func reloadSnapshot(
        resetScope: Bool = true,
        fetchFirst: Bool = false,
        refreshPanes: Bool = false
    ) async {
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
                        branchRecords = listed
                    }
                }

                let snap = try await git.loadSnapshot(repo: repoPath, branch: branch, baseBranch: base)
                guard !Task.isCancelled else { return }
                snapshot = snap
                checkedOutBranch = try? await git.currentBranch(in: repoPath)
                selectedAuthors = selectedAuthors.filter { author in
                    snap.commits.contains { $0.authorName == author }
                }
                if resetScope {
                    changeScope = .combined
                } else if case .commit(let hash) = changeScope,
                          !snap.commits.contains(where: { $0.hash == hash }) {
                    changeScope = .combined
                }
                let shouldRefreshPanes = refreshPanes || fetchFirst
                clearInspectorCache()
                if shouldRefreshPanes {
                    // Drop stale inspector text immediately so panes can't keep pre-fetch content.
                    clearFileInspector()
                    isLoadingFile = true
                }
                isLoading = false
                if fetchFirst, errorMessage == nil {
                    statusMessage = nil
                } else if !fetchFirst {
                    statusMessage = nil
                }
                async let worktreesReload: Void = reloadWorktrees()
                // Snapshot path always rebuilds visible files below — skip nested reload.
                await reloadWorkingTree(updateVisibleFiles: false)
                await worktreesReload
                if historyBrowseMode == .all {
                    await reloadChronologicalCommits(reset: true)
                }
                guard !Task.isCancelled else { return }
                // Rebuild Changed files from the fresh snapshot + working tree, and
                // force-reload file contents after fetch/refresh.
                await reloadVisibleFiles(forceInspectorReload: shouldRefreshPanes)
                if shouldRefreshPanes {
                    contentRefreshNonce &+= 1
                }
                notifyStateChange()
                // PR badges: Current loads the small unique set; All loads lazily per visible card.
                if historyBrowseMode == .current {
                    let forcePR = shouldRefreshPanes
                    Task { await loadCommitPullRequests(for: snap.commits, force: forcePR) }
                }
                Task { await loadMergedIntoCompareIfNeeded(for: snap) }
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                snapshot = nil
                visibleFiles = []
                allChangesWithLocalFiles = []
                mergedIntoCompare = nil
                clearFileInspector()
                errorMessage = error.localizedDescription
                statusMessage = nil
                isLoading = false
            }
        }

        // Wait for the load task so restore can apply post-load selections.
        await loadTask?.value
    }

    /// When BRANCH has nothing unique vs COMPARE, explain why — and only show merged
    /// commits when a PR was actually opened from THIS branch head.
    private func loadMergedIntoCompareIfNeeded(for snap: BranchSnapshot) async {
        mergedIntoCompareTask?.cancel()
        guard snap.commits.isEmpty else {
            mergedIntoCompare = nil
            return
        }

        let branch = snap.branch
        let compareTip = snap.compareTip
        let compareLabel = snap.baseBranch
        let repoPath = snap.repoPath

        mergedIntoCompareTask = Task {
            let contained = await git.isAncestor(branch, of: compareTip, in: repoPath)
            guard !Task.isCancelled else { return }
            guard contained else {
                mergedIntoCompare = nil
                return
            }

            // Important: do NOT infer a PR from the tip commit. When this branch tip
            // matches main, the tip is often someone else's merge commit.
            let pr = try? await github.mergedPullRequest(headBranch: branch, in: repoPath)
            guard !Task.isCancelled else { return }

            if let pr {
                var commits: [GitCommit] = []
                if let shas = try? await github.pullRequestCommitSHAs(number: pr.number, in: repoPath) {
                    for sha in shas.reversed() {
                        if let detail = try? await git.commitDetails(for: sha, in: repoPath) {
                            commits.append(detail)
                        }
                    }
                }
                if commits.isEmpty {
                    commits = (try? await git.commitsMergedIntoCompare(
                        branch: branch,
                        compareTip: compareTip,
                        in: repoPath
                    )) ?? []
                }
                for commit in commits {
                    commitPullRequests[commit.hash] = pr
                    commitPRResolved.insert(commit.hash)
                }
                mergedIntoCompare = MergedIntoCompareInfo(
                    kind: .mergedPR,
                    compareLabel: compareLabel,
                    commits: commits,
                    pullRequest: pr
                )
            } else if await git.revisionsEqual(branch, compareTip, in: repoPath) {
                mergedIntoCompare = MergedIntoCompareInfo(
                    kind: .inSync,
                    compareLabel: compareLabel,
                    commits: [],
                    pullRequest: nil
                )
            } else {
                mergedIntoCompare = MergedIntoCompareInfo(
                    kind: .contained,
                    compareLabel: compareLabel,
                    commits: [],
                    pullRequest: nil
                )
            }
            notifyStateChange()
        }
        await mergedIntoCompareTask?.value
    }

    func selectFile(_ file: ChangedFile) {
        // Keep searchFocusTarget as-is so ⌘F still targets the column the user
        // was interacting with (files filter vs inspector content).
        if case .fileLog = inspectorMode {
            closeFileLog()
        }
        if isEditingFile, selectedFileID != file.id {
            requestLeaveEditingIfNeeded {
                self.applyFileSelection(file)
            }
            return
        }
        applyFileSelection(file)
    }

    private func applyFileSelection(_ file: ChangedFile) {
        let alreadySelected = selectedFileID == file.id && selectedFileIDs == [file.id]
        selectedFileID = file.id
        selectedFileIDs = [file.id]
        selectionAnchorID = file.id
        // Propagate cross-file search into the inspector highlighter.
        let cross = crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cross.isEmpty {
            contentQuery = cross
        }
        notifyStateChange()
        if alreadySelected,
           !(beforeContents == nil && afterContents == nil && fileDiff.isEmpty && !hasImagePreview) {
            return
        }
        Task { await loadFileInspector(for: file) }
    }

    /// ⌘-click: add/remove file from the selection.
    func toggleFileInSelection(_ file: ChangedFile) {
        if isEditingFile {
            requestLeaveEditingIfNeeded { self.performToggleFileInSelection(file) }
            return
        }
        performToggleFileInSelection(file)
    }

    private func performToggleFileInSelection(_ file: ChangedFile) {
        if case .fileLog = inspectorMode {
            closeFileLog()
        }
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
            if selectedFileID == file.id {
                selectedFileID = selectedFileIDs.sorted().first
            }
            if selectionAnchorID == file.id {
                selectionAnchorID = selectedFileID
            }
        } else {
            selectedFileIDs.insert(file.id)
            selectedFileID = file.id
            selectionAnchorID = file.id
        }
        if selectedFileIDs.count == 1, let id = selectedFileIDs.first,
           let only = visibleFiles.first(where: { $0.id == id }) {
            Task { await loadFileInspector(for: only) }
        }
        notifyStateChange()
    }

    /// ⇧-click: select contiguous range from the anchor through `file` (name-filtered order).
    func selectFileRange(to file: ChangedFile) {
        if isEditingFile {
            requestLeaveEditingIfNeeded { self.performSelectFileRange(to: file) }
            return
        }
        performSelectFileRange(to: file)
    }

    private func performSelectFileRange(to file: ChangedFile) {
        if case .fileLog = inspectorMode {
            closeFileLog()
        }
        let order = nameFilteredFiles
        let anchorID = selectionAnchorID ?? selectedFileID
        guard let anchorID,
              let from = order.firstIndex(where: { $0.id == anchorID }),
              let to = order.firstIndex(where: { $0.id == file.id }) else {
            selectFile(file)
            return
        }
        let lo = min(from, to)
        let hi = max(from, to)
        selectedFileIDs = Set(order[lo...hi].map(\.id))
        selectedFileID = file.id
        notifyStateChange()
    }

    /// Click handler that respects ⌘ / ⇧ modifiers.
    func handleFileClick(_ file: ChangedFile) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggleFileInSelection(file)
        } else if flags.contains(.shift) {
            selectFileRange(to: file)
        } else {
            selectFile(file)
        }
    }

    /// Sync from SwiftUI `List(selection:)` multi-select (flat layout).
    func applyListSelection(_ ids: Set<String>) {
        let previous = selectedFileIDs
        if ids == previous { return }
        if isEditingFile {
            let current = selectedFileID.map { Set([$0]) } ?? []
            if ids != current {
                requestLeaveEditingIfNeeded { self.performApplyListSelection(ids) }
                return
            }
        }
        performApplyListSelection(ids)
    }

    private func performApplyListSelection(_ ids: Set<String>) {
        let previous = selectedFileIDs

        if case .fileLog = inspectorMode, ids.count != 1 {
            closeFileLog()
        }

        selectedFileIDs = ids
        if ids.isEmpty {
            selectedFileID = nil
            selectionAnchorID = nil
            clearFileInspector()
            notifyStateChange()
            return
        }

        if ids.count == 1, let id = ids.first {
            selectedFileID = id
            selectionAnchorID = id
            if let file = visibleFiles.first(where: { $0.id == id }) {
                let cross = crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cross.isEmpty { contentQuery = cross }
                Task { await loadFileInspector(for: file) }
            }
            notifyStateChange()
            return
        }

        let added = ids.subtracting(previous)
        let removed = previous.subtracting(ids)
        if added.count == 1, removed.isEmpty {
            selectedFileID = added.first
            selectionAnchorID = added.first
        } else if removed.count >= 1, added.isEmpty {
            if let sel = selectedFileID, !ids.contains(sel) {
                selectedFileID = ids.sorted().first
            }
        } else if !added.isEmpty {
            // Shift-range style update: keep existing anchor when possible.
            if selectionAnchorID == nil || !(previous.contains(selectionAnchorID!)) {
                selectionAnchorID = previous.first ?? added.first
            }
            selectedFileID = added.sorted().first ?? selectedFileID
        }
        notifyStateChange()
    }

    func preferCrossFileSearch() {
        searchFocusTarget = .crossFile
    }

    func openCrossFileSearch() {
        isCrossFileSearchPresented = true
        preferCrossFileSearch()
        searchFocusNonce &+= 1
    }

    func clearCrossFileSearch() {
        crossFileQuery = ""
        crossFileMatchCounts = [:]
        isSearchingCrossFile = false
        crossFileSearchTask?.cancel()
        notifyStateChange()
    }

    func scheduleCrossFileSearch() {
        crossFileSearchTask?.cancel()
        let query = crossFileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            crossFileMatchCounts = [:]
            isSearchingCrossFile = false
            notifyStateChange()
            return
        }

        let files = nameFilteredFiles
        let mode = crossFileSearchMode
        isSearchingCrossFile = true
        crossFileSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            var counts: [String: Int] = [:]
            let chunkSize = 6
            var index = 0
            while index < files.count {
                guard !Task.isCancelled else { return }
                let end = min(index + chunkSize, files.count)
                let chunk = Array(files[index..<end])
                await withTaskGroup(of: (String, Int)?.self) { group in
                    for file in chunk {
                        group.addTask { @MainActor in
                            do {
                                let corpus = try await self.corpusForCrossFileSearch(file: file, mode: mode)
                                let n = TextUtilities.matchCount(in: corpus, query: query)
                                return n > 0 ? (file.id, n) : nil
                            } catch {
                                return nil
                            }
                        }
                    }
                    for await item in group {
                        if let item { counts[item.0] = item.1 }
                    }
                }
                index = end
            }

            guard !Task.isCancelled else { return }
            crossFileMatchCounts = counts
            isSearchingCrossFile = false
            let visibleIDs = Set(
                nameFilteredFiles
                    .filter { counts[$0.id] != nil }
                    .map(\.id)
            )
            selectedFileIDs = selectedFileIDs.intersection(visibleIDs)
            if let sel = selectedFileID, !visibleIDs.contains(sel) {
                selectedFileID = selectedFileIDs.sorted().first ?? visibleIDs.sorted().first
            }
            notifyStateChange()
        }
    }

    private func corpusForCrossFileSearch(file: ChangedFile, mode: CrossFileSearchMode) async throws -> String {
        guard let repoPath else { return "" }
        let key: String
        if let snapshot {
            key = cacheKey(for: file, snapshot: snapshot)
        } else {
            key = [repoPath.path, changeScope.cacheKeyPart, file.path, file.oldPath ?? ""].joined(separator: "|")
        }

        if let cached = inspectorCache[key] {
            return Self.corpus(from: cached, file: file, mode: mode)
        }

        let payload = try await fetchInspectorPayload(for: file)
        storeCache(key: key, payload: payload)
        return Self.corpus(from: payload, file: file, mode: mode)
    }

    private static func corpus(from payload: FileInspectorPayload, file: ChangedFile, mode: CrossFileSearchMode) -> String {
        switch mode {
        case .fullSource:
            if file.status == .deleted {
                return payload.before ?? ""
            }
            return payload.after ?? payload.before ?? ""
        case .modifications:
            return modificationText(from: payload.diff)
        }
    }

    private static func modificationText(from diff: String) -> String {
        DiffParser.parse(diff)
            .filter { $0.kind == .addition || $0.kind == .deletion }
            .map(\.code)
            .joined(separator: "\n")
    }

    func openFileLog(for file: ChangedFile) {
        selectedFileID = file.id
        selectedFileIDs = [file.id]
        selectionAnchorID = file.id
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

    func openCommitPullRequestInBrowser(_ link: CommitPullRequestLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    func pullRequest(forCommitHash hash: String) -> CommitPullRequestLink? {
        commitPullRequests[hash]
    }

    /// Resolve associated PRs for History commits (cached; uses `gh api`).
    func loadCommitPullRequests(for commits: [GitCommit], force: Bool = false) async {
        guard let repoPath else { return }
        guard await github.isAvailable else { return }

        let targets = Array(commits.prefix(commitPRLookupLimit).map(\.hash))
        let missing = force
            ? targets
            : targets.filter { !commitPRResolved.contains($0) }
        guard !missing.isEmpty else { return }

        if force {
            for hash in missing {
                commitPullRequests.removeValue(forKey: hash)
                commitPRResolved.remove(hash)
            }
        }

        commitPRTask?.cancel()
        let github = self.github
        commitPRTask = Task {
            // Bound concurrency so we don't stampede the GitHub API.
            let chunkSize = 6
            var index = 0
            while index < missing.count {
                guard !Task.isCancelled else { return }
                let end = min(index + chunkSize, missing.count)
                let chunk = Array(missing[index..<end])
                await withTaskGroup(of: (String, CommitPullRequestLink?).self) { group in
                    for hash in chunk {
                        group.addTask {
                            do {
                                let prs = try await github.pullRequests(
                                    containingCommit: hash,
                                    in: repoPath
                                )
                                return (hash, Self.preferredCommitPullRequest(from: prs))
                            } catch {
                                return (hash, nil)
                            }
                        }
                    }
                    for await (hash, link) in group {
                        commitPRResolved.insert(hash)
                        if let link {
                            commitPullRequests[hash] = link
                        }
                    }
                }
                index = end
            }
        }
        await commitPRTask?.value
    }

    nonisolated private static func preferredCommitPullRequest(
        from prs: [CommitPullRequestLink]
    ) -> CommitPullRequestLink? {
        // Prefer open, then merged, then closed.
        prs.first(where: { $0.status == "open" })
            ?? prs.first(where: { $0.status == "merged" })
            ?? prs.first
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

    func reloadVisibleFiles(forceInspectorReload: Bool = false) async {
        guard let snapshot else {
            // Local-only scopes can still show working tree files without a branch snapshot.
            if changeScope == .staged || changeScope == .unstaged {
                let files = (changeScope == .staged ? stagedWorkingTreeFiles : unstagedWorkingTreeFiles)
                    .map(\.asChangedFile)
                visibleFiles = files
                syncSelection(to: files, prefer: selectedFileID)
                if let file = selectedFile {
                    await loadFileInspector(for: file)
                } else {
                    clearFileInspector()
                }
                scheduleCrossFileSearch()
            } else {
                visibleFiles = []
                selectedFileIDs = []
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
                        // Net merge-base → worktree (not max of separate branch/local stats).
                        if allChangesWithLocalFiles.isEmpty, !workingTreeFiles.isEmpty || !snapshot.files.isEmpty {
                            await reloadAllChangesWithLocal()
                        }
                        files = allChangesWithLocalFiles
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
                let previousMulti = selectedFileIDs
                let listChanged = visibleFiles != files
                // Assign a fresh array so SwiftUI always sees a Combined-files update
                // even when paths match but stats/content changed after fetch.
                visibleFiles = files
                syncSelection(to: files, prefer: previousSelection, preserving: previousMulti)
                if hasMultiFileSelection {
                    // Keep multi-select panel; no single-file reload.
                } else if let file = selectedFile {
                    if forceInspectorReload || listChanged {
                        clearFileInspector()
                        isLoadingFile = true
                        await loadFileInspector(for: file)
                    }
                } else {
                    clearFileInspector()
                }
                scheduleCrossFileSearch()
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                visibleFiles = []
                selectedFileIDs = []
                clearFileInspector()
                errorMessage = error.localizedDescription
            }
        }
        await scopeTask?.value
    }

    private func syncSelection(
        to files: [ChangedFile],
        prefer preferredID: String?,
        preserving previousMulti: Set<String> = []
    ) {
        let available = Set(files.map(\.id))
        let kept = previousMulti.intersection(available)
        if kept.count > 1 {
            selectedFileIDs = kept
            if let preferredID, kept.contains(preferredID) {
                selectedFileID = preferredID
            } else if let sel = selectedFileID, kept.contains(sel) {
                // keep
            } else {
                selectedFileID = kept.sorted().first
            }
            selectionAnchorID = selectionAnchorID.flatMap { kept.contains($0) ? $0 : nil } ?? selectedFileID
            return
        }
        if let preferredID, available.contains(preferredID) {
            selectedFileID = preferredID
            selectedFileIDs = [preferredID]
            selectionAnchorID = preferredID
        } else if let file = files.first {
            selectedFileID = file.id
            selectedFileIDs = [file.id]
            selectionAnchorID = file.id
        } else {
            selectedFileID = nil
            selectedFileIDs = []
            selectionAnchorID = nil
        }
    }

    private func clearFileInspector() {
        forceEndEditing()
        fileDiff = ""
        beforeContents = nil
        afterContents = nil
        beforeImageData = nil
        afterImageData = nil
        cachedCompareChangedLineNumbers = ([], [])
        cachedCompareChangedLineNumbersDiffID = 0
        isLoadingFile = false
    }

    var selectedFileIsImage: Bool {
        guard let file = selectedFile else { return false }
        return TextUtilities.isImagePath(file.path)
            || TextUtilities.isImagePath(file.oldPath ?? "")
    }

    var hasImagePreview: Bool {
        beforeImageData != nil || afterImageData != nil
    }

    /// True when the inspector can open an inline editor for the on-disk working tree file.
    var canEditWorkingTreeContents: Bool {
        guard showsStagingActions else { return false }
        guard !hasMultiFileSelection, !hasImagePreview, !isLoadingFile else { return false }
        guard let file = selectedFile, file.status != .deleted else { return false }
        switch changeScope {
        case .combined, .unstaged:
            // Text must be loadable (or empty new file). Binary/image → afterContents nil.
            if file.status == .added { return true }
            return afterContents != nil || afterLabel == "Working tree"
        case .staged, .commit:
            return false
        }
    }

    var isEditDraftDirty: Bool {
        guard isEditingFile else { return false }
        return editDraft != editBaseline
    }

    func beginEditingFile() {
        guard canEditWorkingTreeContents, let file = selectedFile else { return }
        showMarkdownPreview = false
        if file.status != .added && file.status != .deleted {
            fileViewMode = .after
        }
        let needsLocal = {
            if case .combined = changeScope { return !includeLocalChanges }
            return false
        }()
        Task {
            if needsLocal {
                includeLocalChanges = true
                await reloadWorkingTree(updateVisibleFiles: false)
                await reloadAllChangesWithLocal()
            }
            await startEditingSession(for: file)
        }
    }

    private func startEditingSession(for file: ChangedFile) async {
        guard let repoPath else { return }
        do {
            let disk = try await git.workingTreeFileContents(in: repoPath, path: file.path)
            editDraft = disk ?? afterContents ?? ""
        } catch {
            editDraft = afterContents ?? ""
        }
        editBaseline = editDraft
        editCanUndo = false
        editCanRedo = false
        editExternallyChanged = false
        editSessionNonce &+= 1
        let url = repoPath.appendingPathComponent(file.path)
        editWatchedURL = url
        editKnownStamp = Self.fileStamp(at: url)
        isEditingFile = true
        startEditFileWatcher()
        notifyStateChange()
    }

    /// Cancel from the UI — confirms when there are unsaved edits.
    func requestCancelEditingFile() {
        requestLeaveEditingIfNeeded {}
    }

    func confirmPendingEditDiscard() {
        let action = pendingEditDiscard?.onDiscard
        pendingEditDiscard = nil
        forceEndEditing()
        action?()
    }

    func dismissPendingEditDiscard() {
        pendingEditDiscard = nil
    }

    /// Discard the edit buffer without prompting.
    func forceEndEditing() {
        let wasEditing = isEditingFile
        stopEditFileWatcher()
        resetEditState()
        if wasEditing {
            notifyStateChange()
        }
    }

    private func resetEditState() {
        isEditingFile = false
        editDraft = ""
        editBaseline = ""
        editCanUndo = false
        editCanRedo = false
        isSavingEdit = false
        editExternallyChanged = false
        editWatchedURL = nil
        editKnownStamp = nil
    }

    private func requestLeaveEditingIfNeeded(proceed: @escaping () -> Void) {
        guard isEditingFile else {
            proceed()
            return
        }
        if isEditDraftDirty {
            let name = selectedFile?.path ?? "this file"
            pendingEditDiscard = PendingEditDiscard(
                title: "Discard unsaved edits?",
                message: "You have unsaved changes to \(name). Discard them?",
                onDiscard: proceed
            )
            return
        }
        forceEndEditing()
        proceed()
    }

    func updateEditUndoState(canUndo: Bool, canRedo: Bool) {
        if editCanUndo != canUndo { editCanUndo = canUndo }
        if editCanRedo != canRedo { editCanRedo = canRedo }
    }

    func undoFileEdit() {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    func redoFileEdit() {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }

    func saveEditingFile() async {
        guard isEditingFile, let file = selectedFile, let repoPath else { return }
        isSavingEdit = true
        errorMessage = nil
        do {
            try await git.writeWorkingTreeFile(in: repoPath, path: file.path, contents: editDraft)
            let url = repoPath.appendingPathComponent(file.path)
            editKnownStamp = Self.fileStamp(at: url)
            editExternallyChanged = false
            stopEditFileWatcher()
            resetEditState()
            clearInspectorCache()
            await reloadWorkingTree(updateVisibleFiles: false)
            await reloadAllChangesWithLocal()
            await reloadVisibleFiles(forceInspectorReload: true)
            contentRefreshNonce &+= 1
            statusMessage = "Saved \(file.path)"
            clearStatusEventually(statusMessage)
            notifyStateChange()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSavingEdit = false
    }

    func reloadEditingFileFromDisk() async {
        guard isEditingFile, let file = selectedFile, let repoPath else { return }
        do {
            let disk = try await git.workingTreeFileContents(in: repoPath, path: file.path) ?? ""
            editDraft = disk
            editBaseline = disk
            editExternallyChanged = false
            editSessionNonce &+= 1
            editCanUndo = false
            editCanRedo = false
            let url = repoPath.appendingPathComponent(file.path)
            editWatchedURL = url
            editKnownStamp = Self.fileStamp(at: url)
            notifyStateChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keep the in-memory buffer; treat the current on-disk stamp as acknowledged.
    func dismissExternalEditChange() {
        if let url = editWatchedURL {
            editKnownStamp = Self.fileStamp(at: url)
        }
        editExternallyChanged = false
    }

    private func startEditFileWatcher() {
        stopEditFileWatcher()
        editWatchTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isEditingFile {
                self.pollEditExternalChange()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        editActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollEditExternalChange()
            }
        }
    }

    private func stopEditFileWatcher() {
        editWatchTask?.cancel()
        editWatchTask = nil
        if let editActiveObserver {
            NotificationCenter.default.removeObserver(editActiveObserver)
            self.editActiveObserver = nil
        }
    }

    private func pollEditExternalChange() {
        guard isEditingFile, let url = editWatchedURL else { return }
        guard let stamp = Self.fileStamp(at: url) else {
            // File vanished — treat as external change if we still have a buffer.
            if editKnownStamp != nil, !editExternallyChanged {
                editExternallyChanged = true
            }
            return
        }
        if let known = editKnownStamp, stamp != known, !editExternallyChanged {
            editExternallyChanged = true
        }
    }

    private static func fileStamp(at url: URL) -> EditFileStamp? {
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return EditFileStamp(mtime: mtime, size: size)
    }

    var selectedFileIsMarkdown: Bool {
        guard let file = selectedFile else { return false }
        return TextUtilities.isMarkdownPath(file.path)
            || TextUtilities.isMarkdownPath(file.oldPath ?? "")
    }

    /// Active markdown source for single-pane preview (After preferred).
    var markdownPreviewSource: String? {
        switch fileViewMode {
        case .before:
            return beforeContents
        case .after, .diff, .compare:
            return afterContents ?? beforeContents
        }
    }

    private func clearInspectorCache() {
        inspectorCache.removeAll(keepingCapacity: true)
        HighlightRenderCache.clear()
    }

    private func cacheKey(for file: ChangedFile, snapshot: BranchSnapshot) -> String {
        // With local included, After is always the worktree — fingerprint on-disk size.
        let localMarker: String
        if includeLocalChanges {
            let url = snapshot.repoPath.appendingPathComponent(file.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            localMarker = "wt-\(size)-\(mtime)"
        } else {
            localMarker = "clean"
        }
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
        fileDiff = Self.cappedText(payload.diff, label: "diff")
        beforeContents = payload.before.map { Self.cappedText($0, label: "file") }
        afterContents = payload.after.map { Self.cappedText($0, label: "file") }
        beforeImageData = payload.beforeImageData
        afterImageData = payload.afterImageData
        beforeLabel = payload.beforeLabel
        afterLabel = payload.afterLabel
        refreshCompareChangedLineNumbersCache()
        isLoadingFile = false
    }

    private func refreshCompareChangedLineNumbersCache() {
        let id = fileDiff.hashValue
        guard id != cachedCompareChangedLineNumbersDiffID else { return }
        cachedCompareChangedLineNumbersDiffID = id
        cachedCompareChangedLineNumbers = DiffParser.changedLineNumbers(in: fileDiff)
    }

    /// Keep inspector text bounded so syntax highlight / hunk cards can't pin the UI.
    private static let maxInspectorTextUTF8Bytes = 1_500_000

    private static func cappedText(_ text: String, label: String) -> String {
        guard let data = text.data(using: .utf8), data.count > maxInspectorTextUTF8Bytes else {
            return text
        }
        let truncated = String(data: data.prefix(maxInspectorTextUTF8Bytes), encoding: .utf8) ?? String(text.prefix(maxInspectorTextUTF8Bytes / 2))
        return truncated
            + "\n\n… [BranchLens truncated this \(label) for performance — open in an editor for the full content]\n"
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
        let targetID = file.id

        fileTask = Task {
            do {
                let payload = try await fetchInspectorPayload(for: file)
                guard !Task.isCancelled else { return }
                storeCache(key: key, payload: payload)
                if selectedFileID == targetID, !hasMultiFileSelection {
                    applyPayload(payload)
                } else {
                    isLoadingFile = false
                }
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                if selectedFileID == targetID, !hasMultiFileSelection {
                    fileDiff = error.localizedDescription
                    beforeContents = nil
                    afterContents = nil
                    beforeImageData = nil
                    afterImageData = nil
                    refreshCompareChangedLineNumbersCache()
                    isLoadingFile = false
                }
            }
        }
        await fileTask?.value
    }

    private func fetchInspectorPayload(for file: ChangedFile) async throws -> FileInspectorPayload {
        guard let repoPath else {
            throw GitError.commandFailed("No repository open.")
        }

        let beforePath = file.oldPath ?? file.path
        let afterPath = file.path
        let scope = changeScope
        let snap = snapshot
        let wantsImages = TextUtilities.isImagePath(afterPath) || TextUtilities.isImagePath(beforePath)

        let diff: String
        let before: String?
        let after: String?
        var beforeImage: Data?
        var afterImage: Data?
        let beforeName: String
        let afterName: String

        switch scope {
        case .combined:
            if let snap {
                // Include-local All changes is always merge-base → worktree (net).
                if includeLocalChanges {
                    async let diffTask = git.worktreeDiff(
                        in: repoPath,
                        from: snap.mergeBase,
                        path: afterPath,
                        oldPath: file.oldPath
                    )
                    async let beforeTask = git.fileContents(in: repoPath, revision: snap.mergeBase, path: beforePath)
                    async let afterTask = git.workingTreeFileContents(in: repoPath, path: afterPath)
                    (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                    if wantsImages {
                        async let beforeImageTask = git.fileData(in: repoPath, revision: snap.mergeBase, path: beforePath)
                        async let afterImageTask = git.workingTreeFileData(in: repoPath, path: afterPath)
                        (beforeImage, afterImage) = try await (beforeImageTask, afterImageTask)
                    }
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
                    if wantsImages {
                        async let beforeImageTask = git.fileData(in: repoPath, revision: snap.mergeBase, path: beforePath)
                        async let afterImageTask = git.fileData(in: repoPath, revision: snap.branch, path: afterPath)
                        (beforeImage, afterImage) = try await (beforeImageTask, afterImageTask)
                    }
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
            if wantsImages {
                async let beforeImageTask = git.fileData(in: repoPath, revision: parent, path: beforePath)
                async let afterImageTask = git.fileData(in: repoPath, revision: hash, path: afterPath)
                (beforeImage, afterImage) = try await (beforeImageTask, afterImageTask)
            }
            beforeName = "parent of \(short)"
            afterName = short
        case .staged:
            async let diffTask = git.stagedDiff(in: repoPath, path: afterPath, oldPath: file.oldPath)
            async let beforeTask = git.fileContents(in: repoPath, revision: "HEAD", path: beforePath)
            async let afterTask = git.indexFileContents(in: repoPath, path: afterPath)
            (diff, before, after) = try await (diffTask, beforeTask, afterTask)
            if wantsImages {
                async let beforeImageTask = git.fileData(in: repoPath, revision: "HEAD", path: beforePath)
                async let afterImageTask = git.indexFileData(in: repoPath, path: afterPath)
                (beforeImage, afterImage) = try await (beforeImageTask, afterImageTask)
            }
            beforeName = "HEAD"
            afterName = "Index (staged)"
        case .unstaged:
            let unstaged = try await git.unstagedDiff(in: repoPath, path: afterPath, oldPath: file.oldPath)
            let worktreeData = wantsImages ? try await git.workingTreeFileData(in: repoPath, path: afterPath) : nil
            let worktree = try await git.workingTreeFileContents(in: repoPath, path: afterPath)
            let index: String?
            let indexData: Data?
            if wantsImages {
                if let fromIndex = try await git.indexFileData(in: repoPath, path: beforePath) {
                    indexData = fromIndex
                    index = fromIndex.contains(0) ? nil : String(data: fromIndex, encoding: .utf8)
                } else if let fromHead = try await git.fileData(in: repoPath, revision: "HEAD", path: beforePath) {
                    indexData = fromHead
                    index = fromHead.contains(0) ? nil : String(data: fromHead, encoding: .utf8)
                } else {
                    indexData = nil
                    index = nil
                }
            } else if let fromIndex = try await git.indexFileContents(in: repoPath, path: beforePath) {
                index = fromIndex
                indexData = nil
            } else {
                index = try await git.fileContents(in: repoPath, revision: "HEAD", path: beforePath)
                indexData = nil
            }
            if unstaged.isEmpty, file.status == .added, (worktree != nil || worktreeData != nil) {
                diff = "--- /dev/null\n+++ b/\(afterPath)\n@@ untracked @@\n"
                before = nil
                after = worktree
                beforeImage = nil
                afterImage = worktreeData
                beforeName = "(new file)"
                afterName = "Working tree"
            } else {
                diff = unstaged
                before = index
                after = worktree
                beforeImage = indexData
                afterImage = worktreeData
                beforeName = "Index / HEAD"
                afterName = "Working tree"
            }
        }

        return FileInspectorPayload(
            diff: diff.isEmpty ? "(No textual diff — binary or empty change.)" : diff,
            before: before,
            after: after,
            beforeImageData: beforeImage,
            afterImageData: afterImage,
            beforeLabel: beforeName,
            afterLabel: afterName
        )
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
