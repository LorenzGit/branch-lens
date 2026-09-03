import AppKit
import BranchLensCore
import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var tabs: [RepoSession] = []
    @Published var activeTabID: UUID?
    @Published var recentRepos: [URL] = RecentRepos.load()
    @Published var tabPendingClose: RepoSession?
    @Published var historyWidth: CGFloat = 270
    @Published var filesWidth: CGFloat = 340
    @Published var isOpenPullRequestPresented = false
    @Published var openPullRequestDraft = ""
    @Published var openPullRequestStatus: String?
    @Published var openPullRequestError: String?
    @Published var isOpeningPullRequest = false

    private var saveTask: Task<Void, Never>?
    private var isRestoring = false
    private let git = GitService()
    private let github = GitHubService()

    var activeSession: RepoSession? {
        guard let activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == activeTabID }) ?? tabs.first
    }

    func openPaths(excluding sessionID: UUID) -> Set<String> {
        Set(tabs.compactMap { tab in
            guard tab.id != sessionID else { return nil }
            return tab.repoPath?.standardizedFileURL.path
        })
    }

    init() {
        // Restore happens asynchronously from ContentView.task so UI can appear first.
    }

    func restoreIfNeeded() async {
        guard !isRestoring, tabs.isEmpty else { return }
        guard let snapshot = SessionPersistence.load(), !snapshot.tabs.isEmpty else { return }

        isRestoring = true
        defer { isRestoring = false }

        historyWidth = CGFloat(snapshot.historyWidth).clamped(to: 200...500)
        filesWidth = CGFloat(snapshot.filesWidth).clamped(to: 220...560)

        var restored: [RepoSession] = []
        for tab in snapshot.tabs {
            let url = URL(fileURLWithPath: tab.repoPath)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let recovered = GitRemoteIdentity.recoverLiveRepository(
                from: url,
                knownPaths: RecentRepos.load() + [
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("git")
                        .appendingPathComponent(url.lastPathComponent)
                ]
            )
            guard exists || recovered != nil else { continue }
            let session = RepoSession(id: tab.id)
            session.onStateChange = { [weak self] in self?.scheduleSave() }
            await session.restore(from: tab)
            if session.repoPath != nil {
                restored.append(session)
            }
        }

        tabs = restored
        if let active = snapshot.activeTabID, restored.contains(where: { $0.id == active }) {
            activeTabID = active
        } else {
            activeTabID = restored.first?.id
        }
        recentRepos = RecentRepos.load()
    }

    func selectTab(_ id: UUID) {
        let changed = activeTabID != id
        activeTabID = id
        scheduleSave()
        if changed {
            Task { await refreshActiveTabIfNeeded() }
        }
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        tabs.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    /// Fetch+reload the active tab if its auto-fetch cooldown has elapsed.
    func refreshActiveTabIfNeeded() async {
        await activeSession?.refreshIfStale()
    }

    func openRepositoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a local git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRepository(at: url) }
    }

    func openRepository(at url: URL) async {
        let session = RepoSession()
        session.onStateChange = { [weak self] in self?.scheduleSave() }
        tabs.append(session)
        activeTabID = session.id
        await session.openRepository(at: url)
        recentRepos = RecentRepos.load()
        scheduleSave()
        objectWillChange.send()
    }

    func beginOpenPullRequest() {
        openPullRequestError = nil
        openPullRequestStatus = nil
        let draft = openPullRequestDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty,
           let paste = NSPasteboard.general.string(forType: .string),
           GitHubPullRequestURL.parse(paste) != nil {
            openPullRequestDraft = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        isOpenPullRequestPresented = true
    }

    func openPullRequest(from raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isOpeningPullRequest else { return }
        openPullRequestDraft = trimmed
        openPullRequestError = nil
        guard let ref = GitHubPullRequestURL.parse(trimmed) else {
            openPullRequestError = "Paste a GitHub pull request URL, like https://github.com/owner/repo/pull/123."
            return
        }

        isOpeningPullRequest = true
        openPullRequestStatus = "Looking up \(ref.nameWithOwner)#\(ref.number)…"
        defer {
            isOpeningPullRequest = false
            openPullRequestStatus = nil
        }

        do {
            guard await github.isAvailable else {
                throw GitError.commandFailed("GitHub CLI (`gh`) is not available. Install it and sign in.")
            }
            let pr = try await github.viewPullRequest(number: ref.number, repo: ref.nameWithOwner)
            openPullRequestStatus = "Finding a local clone of \(ref.nameWithOwner)…"
            guard let clone = await findLocalClone(owner: ref.owner, repo: ref.repo) else {
                openPullRequestError = "No local clone of \(ref.nameWithOwner). Open that repository once, then paste the PR again."
                return
            }

            openPullRequestStatus = "Matching worktree…"
            let worktrees = (try? await git.listWorktrees(in: clone)) ?? []
            let preferredPaths = tabs.compactMap(\.repoPath) + recentRepos
            let target = GitRemoteIdentity.preferredWorktree(
                from: worktrees,
                headBranch: pr.headRefName,
                preferring: preferredPaths
            ) ?? GitRemoteIdentity.fallbackWorktree(from: worktrees)
            let openURL = target?.path ?? clone

            openPullRequestStatus = "Opening \(pr.headRefName)…"
            let session = await sessionForOpening(at: openURL, worktrees: worktrees)
            await session.openRepository(
                at: openURL,
                preferredBranch: pr.headRefName,
                preferredBase: pr.baseRefName
            )
            if session.repoPath == nil {
                openPullRequestError = session.errorMessage ?? "Could not open \(openURL.path)."
                return
            }
            if !session.branches.contains(pr.headRefName) {
                openPullRequestStatus = "Fetching \(pr.headRefName)…"
                if let repoPath = session.repoPath {
                    _ = try? await git.fetchRemotes(in: repoPath)
                    try await git.ensureLocalBranch(pr.headRefName, in: repoPath)
                    await session.openRepository(
                        at: openURL,
                        preferredBranch: pr.headRefName,
                        preferredBase: pr.baseRefName
                    )
                }
            }
            guard session.branches.contains(pr.headRefName) else {
                openPullRequestError = "Found \(openURL.path), but branch “\(pr.headRefName)” is not local. Fetch or check it out, then try again."
                return
            }
            session.selectPullRequest(pr)
            isOpenPullRequestPresented = false
            openPullRequestDraft = ""
            openPullRequestError = nil
        } catch {
            openPullRequestError = error.localizedDescription
        }
    }

    private func findLocalClone(owner: String, repo: String) async -> URL? {
        var seen = Set<String>()
        var candidates: [URL] = []
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            guard FileManager.default.fileExists(atPath: path) else { return }
            candidates.append(url)
        }
        for tab in tabs {
            if let path = tab.repoPath { add(path) }
        }
        recentRepos.forEach(add)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git")
        add(home.appendingPathComponent(repo))
        add(home.appendingPathComponent(owner).appendingPathComponent(repo))
        add(home.appendingPathComponent(owner.lowercased()).appendingPathComponent(repo))

        for candidate in candidates {
            let urls = (try? await git.remoteURLs(in: candidate)) ?? []
            if GitRemoteIdentity.matchesAny(urls, owner: owner, repo: repo) {
                return candidate
            }
        }
        return nil
    }

    private func sessionForOpening(at url: URL, worktrees: [GitWorktree]) async -> RepoSession {
        let standardized = url.standardizedFileURL
        if let existing = tabs.first(where: {
            $0.repoPath?.standardizedFileURL == standardized
                && FileManager.default.fileExists(atPath: standardized.path)
        }) {
            selectTab(existing.id)
            return existing
        }
        let family = Set(GitRemoteIdentity.liveWorktrees(from: worktrees).map { $0.path.standardizedFileURL.path })
        if let existing = tabs.first(where: {
            guard let path = $0.repoPath?.standardizedFileURL.path else { return false }
            return family.contains(path) && FileManager.default.fileExists(atPath: path)
        }) {
            selectTab(existing.id)
            return existing
        }
        let session = RepoSession()
        session.onStateChange = { [weak self] in self?.scheduleSave() }
        tabs.append(session)
        activeTabID = session.id
        scheduleSave()
        objectWillChange.send()
        return session
    }

    func requestClose(_ session: RepoSession) {
        tabPendingClose = session
    }

    func confirmClose() {
        guard let session = tabPendingClose else { return }
        close(session)
        tabPendingClose = nil
    }

    func cancelClose() {
        tabPendingClose = nil
    }

    func close(_ session: RepoSession) {
        tabs.removeAll { $0.id == session.id }
        if activeTabID == session.id {
            activeTabID = tabs.last?.id
        }
        scheduleSave()
    }

    func title(for session: RepoSession) -> String {
        let name = session.repoPath?.lastPathComponent ?? "Repo"
        let sameRepoCount = tabs.filter { $0.repoPath?.path == session.repoPath?.path }.count
        if sameRepoCount > 1, !session.selectedBranch.isEmpty {
            return "\(name) · \(session.selectedBranch)"
        }
        return name
    }

    func scheduleSave() {
        guard !isRestoring else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard !isRestoring else { return }
        let snapshot = WorkspaceSnapshot(
            activeTabID: activeTabID,
            historyWidth: Double(historyWidth),
            filesWidth: Double(filesWidth),
            tabs: tabs.compactMap { $0.makeSnapshot() }
        )
        SessionPersistence.save(snapshot)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
