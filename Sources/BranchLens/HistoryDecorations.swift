import BranchLensCore
import Combine
import Foundation

/// History-only badges and +/- stats.
/// Kept off `RepoSession` so streaming PR/stat lookups do not rebuild Files or the inspector.
@MainActor
final class HistoryDecorations: ObservableObject {
    private(set) var commitPullRequests: [String: CommitPullRequestLink] = [:]
    private(set) var commitChangeStats: [String: CommitChangeStats] = [:]
    private(set) var pullRequestChangeStats: [Int: CommitChangeStats] = [:]
    private(set) var commitPRResolved: Set<String> = []
    private(set) var commitStatsResolved: Set<String> = []
    private(set) var pullRequestStatsResolved: Set<Int> = []

    private var pendingPRs: [String: CommitPullRequestLink] = [:]
    private var pendingCommitStats: [String: CommitChangeStats] = [:]
    private var pendingPullRequestStats: [Int: CommitChangeStats] = [:]
    private var flushTask: Task<Void, Never>?

    private static let flushDelayNanoseconds: UInt64 = 50_000_000

    func resetCommitDecorations() {
        cancelPendingFlush()
        objectWillChange.send()
        commitPullRequests = [:]
        commitChangeStats = [:]
        commitPRResolved = []
        commitStatsResolved = []
    }

    func resetPullRequestStats() {
        pendingPullRequestStats.removeAll()
        objectWillChange.send()
        pullRequestChangeStats = [:]
        pullRequestStatsResolved = []
    }

    func markCommitStatsResolved(_ hash: String) {
        commitStatsResolved.insert(hash)
    }

    func markPullRequestStatsResolved(_ number: Int) {
        pullRequestStatsResolved.insert(number)
    }

    func unmarkPullRequestStatsResolved(_ number: Int) {
        pullRequestStatsResolved.remove(number)
    }

    func removeCommitPRs(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        objectWillChange.send()
        for hash in hashes {
            commitPRResolved.remove(hash)
            pendingPRs.removeValue(forKey: hash)
            commitPullRequests.removeValue(forKey: hash)
        }
    }

    /// Immediate write for lookups that should regroup History in the same turn.
    func recordCommitPRsNow(_ links: [String: CommitPullRequestLink]) {
        guard !links.isEmpty else { return }
        objectWillChange.send()
        for (hash, link) in links {
            commitPRResolved.insert(hash)
            pendingPRs.removeValue(forKey: hash)
            commitPullRequests[hash] = link
        }
    }

    func recordCommitPR(hash: String, link: CommitPullRequestLink?) {
        commitPRResolved.insert(hash)
        guard let link else { return }
        pendingPRs[hash] = link
        scheduleFlush()
    }

    func recordCommitStats(hash: String, stats: CommitChangeStats) {
        pendingCommitStats[hash] = stats
        scheduleFlush()
    }

    func recordPullRequestStats(number: Int, stats: CommitChangeStats) {
        pendingPullRequestStats[number] = stats
        scheduleFlush()
    }

    private func cancelPendingFlush() {
        flushTask?.cancel()
        flushTask = nil
        pendingPRs.removeAll()
        pendingCommitStats.removeAll()
        pendingPullRequestStats.removeAll()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.flushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        let prs = pendingPRs
        let stats = pendingCommitStats
        let prStats = pendingPullRequestStats
        pendingPRs.removeAll()
        pendingCommitStats.removeAll()
        pendingPullRequestStats.removeAll()
        guard !prs.isEmpty || !stats.isEmpty || !prStats.isEmpty else { return }
        objectWillChange.send()
        for (hash, link) in prs {
            commitPullRequests[hash] = link
        }
        for (hash, value) in stats {
            commitChangeStats[hash] = value
        }
        for (number, value) in prStats {
            pullRequestChangeStats[number] = value
        }
    }
}
