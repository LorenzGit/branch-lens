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
    case combined
    case commit(String)

    var cacheKeyPart: String {
        switch self {
        case .combined: return "combined"
        case .commit(let hash): return "commit:\(hash)"
        }
    }
}

enum SearchFocusTarget: Hashable {
    case fileFilter
    case content
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
    @Published var isLoading = false
    @Published var isLoadingFile = false
    @Published var isUpdatingFromCompare = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var searchFocusTarget: SearchFocusTarget = .content
    /// Bumped to force the matching search field to become first responder (⌘F).
    @Published var searchFocusNonce: Int = 0

    private let git = GitService()
    private var loadTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var scopeTask: Task<Void, Never>?
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
        case .combined:
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
            fileNameQuery: fileNameQuery
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
        await reloadVisibleFiles()
        notifyStateChange()
    }

    var selectedFile: ChangedFile? {
        guard let selectedFileID else { return nil }
        return visibleFiles.first { $0.id == selectedFileID }
            ?? filteredFiles.first { $0.id == selectedFileID }
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
        }
    }

    var scopeCommitSummary: String {
        guard let commit = activeScopeCommit else {
            return changeScope == .combined ? "No commits" : "Commit"
        }
        let date = commit.authoredDate.formatted(date: .abbreviated, time: .shortened)
        return "\(commit.shortHash) · \(commit.authorName) · \(date)"
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

    func selectCombined() {
        changeScope = .combined
        notifyStateChange()
        Task { await reloadVisibleFiles() }
    }

    func selectCommit(_ commit: GitCommit) {
        changeScope = .commit(commit.hash)
        notifyStateChange()
        Task { await reloadVisibleFiles() }
    }

    /// Toolbar refresh: fetch remotes, then reload branches + snapshot.
    func refresh() async {
        await reloadSnapshot(resetScope: false, fetchFirst: true)
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
            try await git.merge(source: baseBranch, into: selectedBranch, in: repoPath)
            await reloadSnapshot(resetScope: true, fetchFirst: false)
            statusMessage = "Updated \(selectedBranch) with \(baseBranch)."
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
                await reloadVisibleFiles()
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
        let alreadySelected = selectedFileID == file.id
        selectedFileID = file.id
        notifyStateChange()
        if alreadySelected, !(beforeContents == nil && afterContents == nil && fileDiff.isEmpty) {
            return
        }
        Task { await loadFileInspector(for: file) }
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
            visibleFiles = []
            return
        }

        scopeTask?.cancel()
        scopeTask = Task {
            do {
                let files: [ChangedFile]
                switch changeScope {
                case .combined:
                    files = snapshot.files
                case .commit(let hash):
                    files = try await git.commitChangedFiles(in: snapshot.repoPath, commit: hash)
                }
                guard !Task.isCancelled else { return }
                visibleFiles = files
                if let current = selectedFileID, files.contains(where: { $0.id == current }) {
                    if let file = files.first(where: { $0.id == current }) {
                        await loadFileInspector(for: file)
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
        [
            snapshot.repoPath.path,
            snapshot.branch,
            snapshot.baseBranch,
            snapshot.mergeBase,
            changeScope.cacheKeyPart,
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
        guard let snapshot else { return }
        let key = cacheKey(for: file, snapshot: snapshot)

        if let cached = inspectorCache[key] {
            applyPayload(cached)
            return
        }

        // Avoid cancelling an in-flight load for the same file.
        fileTask?.cancel()
        isLoadingFile = true
        // Keep previous file visible until the new payload arrives (no flicker/clear).

        let repo = snapshot.repoPath
        let beforePath = file.oldPath ?? file.path
        let afterPath = file.path
        let scope = changeScope

        fileTask = Task {
            do {
                let diff: String
                let before: String?
                let after: String?
                let beforeName: String
                let afterName: String

                switch scope {
                case .combined:
                    async let diffTask = git.fileDiff(
                        in: repo,
                        from: snapshot.mergeBase,
                        to: snapshot.branch,
                        path: file.path,
                        oldPath: file.oldPath
                    )
                    async let beforeTask = git.fileContents(in: repo, revision: snapshot.mergeBase, path: beforePath)
                    async let afterTask = git.fileContents(in: repo, revision: snapshot.branch, path: afterPath)
                    (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                    beforeName = "\(snapshot.baseBranch) @ \(snapshot.mergeBaseShort)"
                    afterName = snapshot.branch
                case .commit(let hash):
                    let short = snapshot.commits.first(where: { $0.hash == hash })?.shortHash ?? String(hash.prefix(8))
                    let parent = "\(hash)^"
                    async let diffTask = git.commitFileDiff(
                        in: repo,
                        commit: hash,
                        path: file.path,
                        oldPath: file.oldPath
                    )
                    async let beforeTask = git.fileContents(in: repo, revision: parent, path: beforePath)
                    async let afterTask = git.fileContents(in: repo, revision: hash, path: afterPath)
                    (diff, before, after) = try await (diffTask, beforeTask, afterTask)
                    beforeName = "parent of \(short)"
                    afterName = short
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
                // Only apply if this file is still selected.
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
