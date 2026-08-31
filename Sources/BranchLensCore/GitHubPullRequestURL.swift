import Foundation

public struct GitHubPullRequestRef: Equatable, Sendable {
    public let host: String
    public let owner: String
    public let repo: String
    public let number: Int

    public init(host: String, owner: String, repo: String, number: Int) {
        self.host = host
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    public var nameWithOwner: String { "\(owner)/\(repo)" }
}

public enum GitHubPullRequestURL {
    /// Accepts github.com PR links, with or without scheme, plus `#fragment` / extra path.
    public static func parse(_ raw: String) -> GitHubPullRequestRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if candidate.hasPrefix("github.com/") || candidate.hasPrefix("www.github.com/") {
            candidate = "https://\(candidate)"
        }

        guard let url = URL(string: candidate),
              let host = url.host?.lowercased()
        else { return nil }

        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "github.com" else { return nil }

        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        let pullWord = parts[2].lowercased()
        guard pullWord == "pull" || pullWord == "pulls", parts.count >= 4 else { return nil }
        guard let number = Int(parts[3]), number > 0 else { return nil }
        guard !owner.isEmpty, !repo.isEmpty, owner != "." , repo != "." else { return nil }
        return GitHubPullRequestRef(host: normalizedHost, owner: owner, repo: repo, number: number)
    }
}

public enum GitRemoteIdentity {
    /// `owner/repo` from an SSH or HTTPS Git remote, if the remote is GitHub.
    public static func nameWithOwner(from remoteURL: String) -> String? {
        guard let parsed = parse(remoteURL) else { return nil }
        return "\(parsed.owner)/\(parsed.repo)"
    }

    public static func matches(_ remoteURL: String, owner: String, repo: String) -> Bool {
        guard let parsed = parse(remoteURL) else { return false }
        return parsed.owner.caseInsensitiveCompare(owner) == .orderedSame
            && parsed.repo.caseInsensitiveCompare(repo) == .orderedSame
    }

    public static func matchesAny(_ remoteURLs: [String], owner: String, repo: String) -> Bool {
        remoteURLs.contains { matches($0, owner: owner, repo: repo) }
    }

    public static func preferredWorktree(
        from worktrees: [GitWorktree],
        headBranch: String,
        preferring paths: [URL] = []
    ) -> GitWorktree? {
        let matches = worktrees.filter { $0.branch == headBranch }
        guard !matches.isEmpty else { return nil }
        let preferred = Set(paths.map { $0.standardizedFileURL.path })
        return matches.first { preferred.contains($0.path.standardizedFileURL.path) } ?? matches[0]
    }

    public static func fallbackWorktree(from worktrees: [GitWorktree]) -> GitWorktree? {
        worktrees.first { !$0.isBare && !$0.isDetached } ?? worktrees.first { !$0.isBare }
    }

    private static func parse(_ remoteURL: String) -> (host: String, owner: String, repo: String)? {
        var value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasSuffix(".git") {
            value = String(value.dropLast(4))
        }

        // git@github.com:Owner/Repo
        if let at = value.firstIndex(of: "@"), value[at...].contains(":"),
           !value.hasPrefix("ssh://"), !value.hasPrefix("git://"),
           !value.hasPrefix("http://"), !value.hasPrefix("https://") {
            let host = String(value[value.index(after: at)..<value.firstIndex(of: ":")!]).lowercased()
            let path = String(value[value.index(after: value.firstIndex(of: ":")!)...])
            return pathComponents(host: host, path: path)
        }

        var path = value
        var host = "github.com"
        if let schemeRange = path.range(of: "://") {
            path = String(path[schemeRange.upperBound...])
            if let slash = path.firstIndex(of: "/") {
                var hostPart = String(path[..<slash])
                if let at = hostPart.firstIndex(of: "@") {
                    hostPart = String(hostPart[hostPart.index(after: at)...])
                }
                if let colon = hostPart.firstIndex(of: ":") {
                    hostPart = String(hostPart[..<colon])
                }
                host = hostPart.lowercased()
                path = String(path[path.index(after: slash)...])
            }
        }
        return pathComponents(host: host, path: path)
    }

    private static func pathComponents(host: String, path: String) -> (host: String, owner: String, repo: String)? {
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "github.com" else { return nil }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (normalizedHost, owner, repo)
    }
}
