import AppKit
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

    private var saveTask: Task<Void, Never>?
    private var isRestoring = false

    var activeSession: RepoSession? {
        guard let activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == activeTabID }) ?? tabs.first
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
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
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
