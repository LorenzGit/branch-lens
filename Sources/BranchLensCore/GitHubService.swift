import Foundation

/// Lists pull requests via the GitHub CLI (`gh`), using the user's existing auth.
public actor GitHubService {
    private let ghURL: URL?

    public init() {
        self.ghURL = Self.resolveGH()
    }

    public var isAvailable: Bool { ghURL != nil }

    public func listPullRequests(
        in repo: URL,
        state: PullRequestState,
        limit: Int = 50
    ) async throws -> [PullRequestSummary] {
        guard let ghURL else {
            throw GitError.commandFailed(
                "GitHub CLI (`gh`) not found. Install it and run `gh auth login`."
            )
        }

        let result = try await ProcessRunner.run(
            executable: ghURL,
            arguments: [
                "pr", "list",
                "--state", state.rawValue,
                "--limit", String(limit),
                "--json", "number,title,author,headRefName,baseRefName,updatedAt,url,isDraft,state",
            ],
            currentDirectory: repo
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty
                    ? "gh pr list failed (\(result.status)). Is this a GitHub repo and is `gh` authenticated?"
                    : message
            )
        }

        return try decodePullRequests(from: result.stdout)
    }

    private func decodePullRequests(from data: Data) throws -> [PullRequestSummary] {
        struct Payload: Decodable {
            struct Author: Decodable { let login: String }
            let number: Int
            let title: String
            let author: Author?
            let headRefName: String
            let baseRefName: String
            let updatedAt: String
            let url: String
            let isDraft: Bool
            let state: String
        }

        let rows = try JSONDecoder().decode([Payload].self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        return rows.map { row in
            let state = PullRequestState(rawValue: row.state.lowercased())
                ?? (row.state.lowercased() == "merged" ? .closed : .open)
            let date = iso.date(from: row.updatedAt)
                ?? isoBasic.date(from: row.updatedAt)
                ?? Date.distantPast
            return PullRequestSummary(
                number: row.number,
                title: row.title,
                state: state,
                authorLogin: row.author?.login ?? "unknown",
                headRefName: row.headRefName,
                baseRefName: row.baseRefName,
                updatedAt: date,
                url: row.url,
                isDraft: row.isDraft
            )
        }
    }

    private static func resolveGH() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Fall back to a login shell PATH (GUI apps often lack Homebrew).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v gh"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }
}
