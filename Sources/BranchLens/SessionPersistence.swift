import Foundation

struct TabSnapshot: Codable, Equatable {
    var id: UUID
    var repoPath: String
    var selectedBranch: String
    var baseBranch: String
    var scopeIsCombined: Bool
    var selectedCommitHash: String?
    var selectedFileID: String?
    var fileViewMode: String
    var filesLayout: String
    var showHistory: Bool
    var showFiles: Bool
    var selectedAuthors: [String]
    var fileNameQuery: String
}

struct WorkspaceSnapshot: Codable, Equatable {
    var version: Int = 1
    var activeTabID: UUID?
    var historyWidth: Double
    var filesWidth: Double
    var tabs: [TabSnapshot]
}

enum SessionPersistence {
    private static let key = "BranchLens.workspaceSnapshot.v1"

    static func load() -> WorkspaceSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    static func save(_ snapshot: WorkspaceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
