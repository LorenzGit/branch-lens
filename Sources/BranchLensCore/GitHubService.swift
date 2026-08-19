import Foundation

/// Lists pull requests via the GitHub CLI (`gh`), using the user's existing auth.
public actor GitHubService {
    private let ghURL: URL?
    private var nameWithOwnerCache: [String: String] = [:]

    public init() {
        self.ghURL = Self.resolveGH()
    }

    public var isAvailable: Bool { ghURL != nil }

    public func listPullRequests(
        in repo: URL,
        state: PullRequestState,
        limit: Int = 50
    ) async throws -> [PullRequestSummary] {
        let ghURL = try requireGH()

        let fieldsWithStats = "number,title,author,headRefName,baseRefName,updatedAt,url,isDraft,state,additions,deletions,changedFiles"
        let fields = "number,title,author,headRefName,baseRefName,updatedAt,url,isDraft,state"
        var result = try await ProcessRunner.run(
            executable: ghURL,
            arguments: [
                "pr", "list",
                "--state", state.rawValue,
                "--limit", String(limit),
                "--json", fieldsWithStats,
            ],
            currentDirectory: repo
        )
        if result.status != 0 {
            result = try await ProcessRunner.run(
                executable: ghURL,
                arguments: [
                    "pr", "list",
                    "--state", state.rawValue,
                    "--limit", String(limit),
                    "--json", fields,
                ],
                currentDirectory: repo
            )
        }
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

    /// Most recently merged PR whose head branch matches `headBranch`.
    public func mergedPullRequest(
        headBranch: String,
        in repo: URL
    ) async throws -> CommitPullRequestLink? {
        let ghURL = try requireGH()
        let result = try await ProcessRunner.run(
            executable: ghURL,
            arguments: [
                "pr", "list",
                "--head", headBranch,
                "--state", "merged",
                "--limit", "1",
                "--json", "number,title,url,state,isDraft",
            ],
            currentDirectory: repo
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty
                    ? "gh pr list failed (\(result.status))"
                    : message
            )
        }

        struct Payload: Decodable {
            let number: Int
            let title: String
            let url: String
            let state: String
            let isDraft: Bool?
        }
        let rows = try JSONDecoder().decode([Payload].self, from: result.stdout)
        guard let row = rows.first else { return nil }
        return CommitPullRequestLink(
            number: row.number,
            title: row.title,
            url: row.url,
            isDraft: row.isDraft ?? false,
            status: "merged"
        )
    }

    /// Commit SHAs that belong to a pull request (newest first from GitHub).
    public func pullRequestCommitSHAs(
        number: Int,
        in repo: URL
    ) async throws -> [String] {
        let ghURL = try requireGH()
        let result = try await ProcessRunner.run(
            executable: ghURL,
            arguments: [
                "pr", "view", String(number),
                "--json", "commits",
                "--jq", "[.commits[].oid]",
            ],
            currentDirectory: repo
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty
                    ? "gh pr view failed (\(result.status))"
                    : message
            )
        }
        return try JSONDecoder().decode([String].self, from: result.stdout)
    }

    /// PRs that contain `commit` (open, merged, or closed), via GitHub's commit→PR API.
    public func pullRequests(
        containingCommit commit: String,
        in repo: URL
    ) async throws -> [CommitPullRequestLink] {
        let ghURL = try requireGH()
        let nameWithOwner = try await resolveNameWithOwner(in: repo)
        let result = try await ProcessRunner.run(
            executable: ghURL,
            arguments: [
                "api",
                "repos/\(nameWithOwner)/commits/\(commit)/pulls",
                "--jq",
                "[.[] | {number, title, html_url, state, draft, merged_at}]",
            ],
            currentDirectory: repo
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty
                    ? "gh api commit pulls failed (\(result.status))"
                    : message
            )
        }
        return try decodeCommitPullRequests(from: result.stdout)
    }

    private func requireGH() throws -> URL {
        guard let ghURL else {
            throw GitError.commandFailed(
                "GitHub CLI (`gh`) not found. Install it and run `gh auth login`."
            )
        }
        return ghURL
    }

    private func resolveNameWithOwner(in repo: URL) async throws -> String {
        let key = repo.path
        if let cached = nameWithOwnerCache[key] {
            return cached
        }
        let ghURL = try requireGH()
        let result = try await ProcessRunner.run(
            executable: ghURL,
            arguments: ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            currentDirectory: repo
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty
                    ? "gh repo view failed (\(result.status))"
                    : message
            )
        }
        let value = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw GitError.commandFailed("Could not resolve GitHub repository name.")
        }
        nameWithOwnerCache[key] = value
        return value
    }

    private func decodeCommitPullRequests(from data: Data) throws -> [CommitPullRequestLink] {
        struct Payload: Decodable {
            let number: Int
            let title: String
            let html_url: String
            let state: String
            let draft: Bool?
            let merged_at: String?
        }

        let rows = try JSONDecoder().decode([Payload].self, from: data)
        return rows.map { row in
            let lower = row.state.lowercased()
            let status: String
            if row.merged_at != nil {
                status = "merged"
            } else if lower == "open" {
                status = "open"
            } else {
                status = "closed"
            }
            return CommitPullRequestLink(
                number: row.number,
                title: row.title,
                url: row.html_url,
                isDraft: row.draft ?? false,
                status: status
            )
        }
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
            let additions: Int?
            let deletions: Int?
            let changedFiles: Int?
        }

        let rows = try JSONDecoder().decode([Payload].self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        return rows.map { row in
            let lower = row.state.lowercased()
            let status: String
            if lower == "merged" {
                status = "merged"
            } else if lower == "open" {
                status = "open"
            } else {
                status = "closed"
            }
            let state = PullRequestState(rawValue: lower)
                ?? (status == "open" ? .open : .closed)
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
                isDraft: row.isDraft,
                status: status,
                changedFiles: row.changedFiles,
                additions: row.additions,
                deletions: row.deletions
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
