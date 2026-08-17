import Foundation

/// One row in Current-mode History: a single commit, or several commits collapsed into one PR.
public enum HistoryListItem: Identifiable, Equatable, Sendable {
    case commit(GitCommit)
    case pullRequest(CommitPullRequestLink, commits: [GitCommit])

    public var id: String {
        switch self {
        case .commit(let commit):
            return "c-\(commit.hash)"
        case .pullRequest(let pullRequest, _):
            return "pr-\(pullRequest.number)"
        }
    }

    public var commits: [GitCommit] {
        switch self {
        case .commit(let commit):
            return [commit]
        case .pullRequest(_, let commits):
            return commits
        }
    }

    /// Newest non-merge commit, else the newest commit in the row.
    public var primaryCommit: GitCommit {
        commits.first { !$0.isMerge } ?? commits[0]
    }
}

public enum HistoryListBuilder {
    /// Walk newest → oldest along `parents[0]`. Side-branch commits from merges are excluded.
    public static func firstParentHashes(in commits: [GitCommit]) -> Set<String> {
        let byHash = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0) })
        guard let tip = commits.first else { return [] }
        var result = Set<String>()
        var current: String? = tip.hash
        while let hash = current, result.insert(hash).inserted {
            current = byHash[hash]?.parents.first
        }
        return result
    }

    /// This branch's own work: first-parent commits, minus merge commits that only brought other history in.
    public static func currentBranchCommits(
        allRangeCommits: [GitCommit],
        displayed: [GitCommit]
    ) -> [GitCommit] {
        let firstParent = firstParentHashes(in: allRangeCommits)
        return displayed.filter { firstParent.contains($0.hash) && !$0.isMerge }
    }

    /// Collapse commits that share a PR number into one row. Commits with no PR stay separate.
    public static func items(
        visibleCommits: [GitCommit],
        pullRequests: [String: CommitPullRequestLink]
    ) -> [HistoryListItem] {
        var emittedPRs = Set<Int>()
        var items: [HistoryListItem] = []
        for commit in visibleCommits {
            guard let pullRequest = pullRequests[commit.hash] else {
                items.append(.commit(commit))
                continue
            }
            guard emittedPRs.insert(pullRequest.number).inserted else { continue }
            let group = visibleCommits.filter { pullRequests[$0.hash]?.number == pullRequest.number }
            if group.count == 1 {
                items.append(.commit(commit))
            } else {
                items.append(.pullRequest(pullRequest, commits: group))
            }
        }
        return items
    }
}
