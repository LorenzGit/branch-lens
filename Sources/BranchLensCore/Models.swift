import Foundation

public struct GitBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let tipDate: Date

    public init(name: String, tipDate: Date) {
        self.name = name
        self.tipDate = tipDate
    }
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let authorName: String
    public let authorEmail: String
    public let authoredDate: Date
    public let parents: [String]

    public init(
        hash: String,
        shortHash: String,
        subject: String,
        authorName: String,
        authorEmail: String,
        authoredDate: Date,
        parents: [String]
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredDate = authoredDate
        self.parents = parents
    }
}

public enum FileChangeStatus: String, Sendable, Hashable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
    case unknown = "?"

    public var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .unmerged: return "Unmerged"
        case .unknown: return "Changed"
        }
    }
}

public struct ChangedFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let status: FileChangeStatus
    public let path: String
    public let oldPath: String?
    public let additions: Int
    public let deletions: Int

    public init(
        status: FileChangeStatus,
        path: String,
        oldPath: String? = nil,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
        self.additions = additions
        self.deletions = deletions
    }
}

public struct BranchSnapshot: Sendable {
    public let repoPath: URL
    public let branch: String
    public let baseBranch: String
    public let mergeBase: String
    public let mergeBaseShort: String
    public let commits: [GitCommit]
    public let files: [ChangedFile]
    /// Commits on the fresh COMPARE tip that are not on `branch` (how far behind COMPARE you are).
    public let compareAheadCount: Int
    /// Revision used for the behind count / update (often `origin/main`, not stale local `main`).
    public let compareTip: String
    /// Commits on `compareTip` that are missing from the local COMPARE branch name (stale local `main`).
    public let localCompareBehindCount: Int
    /// History commits that are already on `compareTip` and only appear because local COMPARE is stale.
    public let staleCompareInheritedCommitCount: Int
    public let aheadOfRemote: Int?
    public let behindRemote: Int?
    public let remoteTrackingBranch: String?

    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    public init(
        repoPath: URL,
        branch: String,
        baseBranch: String,
        mergeBase: String,
        mergeBaseShort: String,
        commits: [GitCommit],
        files: [ChangedFile],
        compareAheadCount: Int,
        compareTip: String,
        localCompareBehindCount: Int,
        staleCompareInheritedCommitCount: Int = 0,
        aheadOfRemote: Int?,
        behindRemote: Int?,
        remoteTrackingBranch: String?
    ) {
        self.repoPath = repoPath
        self.branch = branch
        self.baseBranch = baseBranch
        self.mergeBase = mergeBase
        self.mergeBaseShort = mergeBaseShort
        self.commits = commits
        self.files = files
        self.compareAheadCount = compareAheadCount
        self.compareTip = compareTip
        self.localCompareBehindCount = localCompareBehindCount
        self.staleCompareInheritedCommitCount = staleCompareInheritedCommitCount
        self.aheadOfRemote = aheadOfRemote
        self.behindRemote = behindRemote
        self.remoteTrackingBranch = remoteTrackingBranch
    }
}

public struct FileLogEntry: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let authorName: String
    public let authorEmail: String
    public let authoredDate: Date
    /// Decoration from `git log` (branch/tag tips pointing at this commit).
    public let decorations: String

    public init(
        hash: String,
        shortHash: String,
        subject: String,
        authorName: String,
        authorEmail: String,
        authoredDate: Date,
        decorations: String
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredDate = authoredDate
        self.decorations = decorations
    }
}

public enum PullRequestState: String, Sendable, Hashable, CaseIterable, Identifiable {
    case open
    case closed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        }
    }
}

public enum WorkingTreeArea: String, Sendable, Hashable, CaseIterable, Identifiable {
    case staged
    case unstaged

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .staged: return "Staged"
        case .unstaged: return "Unstaged"
        }
    }
}

public struct WorkingTreeFile: Identifiable, Hashable, Sendable {
    public var id: String { "\(area.rawValue)|\(path)" }
    public let area: WorkingTreeArea
    public let status: FileChangeStatus
    public let path: String
    public let oldPath: String?
    public let additions: Int
    public let deletions: Int

    public init(
        area: WorkingTreeArea,
        status: FileChangeStatus,
        path: String,
        oldPath: String? = nil,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.area = area
        self.status = status
        self.path = path
        self.oldPath = oldPath
        self.additions = additions
        self.deletions = deletions
    }

    public var asChangedFile: ChangedFile {
        ChangedFile(status: status, path: path, oldPath: oldPath, additions: additions, deletions: deletions)
    }
}

public struct GitWorktree: Identifiable, Hashable, Sendable {
    public var id: String { path.path }
    public let path: URL
    public let head: String
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool

    public init(
        path: URL,
        head: String,
        branch: String?,
        isBare: Bool,
        isDetached: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
    }

    public var displayName: String {
        let folder = path.lastPathComponent
        if let branch, !branch.isEmpty {
            return "\(folder) · \(branch)"
        }
        if isDetached {
            return "\(folder) · detached \(String(head.prefix(8)))"
        }
        return folder
    }
}

public struct PullRequestSummary: Identifiable, Hashable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let state: PullRequestState
    public let authorLogin: String
    public let headRefName: String
    public let baseRefName: String
    public let updatedAt: Date
    public let url: String
    public let isDraft: Bool

    public init(
        number: Int,
        title: String,
        state: PullRequestState,
        authorLogin: String,
        headRefName: String,
        baseRefName: String,
        updatedAt: Date,
        url: String,
        isDraft: Bool
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.authorLogin = authorLogin
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.updatedAt = updatedAt
        self.url = url
        self.isDraft = isDraft
    }
}

/// Compact PR association for a commit (History cards).
public struct CommitPullRequestLink: Identifiable, Hashable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: String
    public let isDraft: Bool
    /// open | closed | merged
    public let status: String

    public init(
        number: Int,
        title: String,
        url: String,
        isDraft: Bool,
        status: String
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.status = status
    }

    public var badgeLabel: String {
        if isDraft, status == "open" {
            return "Draft #\(number)"
        }
        switch status {
        case "open": return "Open #\(number)"
        case "merged": return "Merged #\(number)"
        default: return "Closed #\(number)"
        }
    }
}

public enum GitError: LocalizedError, Sendable {
    case notARepository(URL)
    case commandFailed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let url):
            return "Not a git repository: \(url.path)"
        case .commandFailed(let message):
            return message
        case .invalidOutput(let message):
            return message
        }
    }
}
