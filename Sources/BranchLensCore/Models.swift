import Foundation

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
        self.aheadOfRemote = aheadOfRemote
        self.behindRemote = behindRemote
        self.remoteTrackingBranch = remoteTrackingBranch
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
