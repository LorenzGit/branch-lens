import Foundation

public actor GitService {
    private let gitURL: URL

    public init(gitPath: String = "/usr/bin/git") {
        self.gitURL = URL(fileURLWithPath: gitPath)
    }

    public func validateRepository(at url: URL) async throws -> URL {
        let root = try await runGit(
            ["rev-parse", "--show-toplevel"],
            in: url
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw GitError.notARepository(url)
        }
        return URL(fileURLWithPath: root)
    }

    public func listBranches(in repo: URL) async throws -> [String] {
        let output = try await runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads/"],
            in: repo
        )
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    public func currentBranch(in repo: URL) async throws -> String? {
        let output = try await runGit(
            ["branch", "--show-current"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// Prefer origin/HEAD, then main, then master, then the first local branch.
    public func detectBaseBranch(in repo: URL, branches: [String]) async throws -> String? {
        if let symbolic = try? await runGit(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines),
           !symbolic.isEmpty {
            let name = symbolic.replacingOccurrences(of: "origin/", with: "")
            if branches.contains(name) { return name }
        }

        for candidate in ["main", "master", "develop"] where branches.contains(candidate) {
            return candidate
        }
        return branches.first
    }

    public func loadSnapshot(
        repo: URL,
        branch: String,
        baseBranch: String
    ) async throws -> BranchSnapshot {
        let mergeBase = try await runGit(
            ["merge-base", baseBranch, branch],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !mergeBase.isEmpty else {
            throw GitError.commandFailed("Could not find merge base of \(baseBranch) and \(branch).")
        }

        let mergeBaseShort = try await runGit(
            ["rev-parse", "--short", mergeBase],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let commits = try await listCommits(in: repo, from: mergeBase, to: branch)
        let files = try await listChangedFiles(in: repo, from: mergeBase, to: branch)
        let remote = try await remoteTrackingInfo(in: repo, branch: branch)

        return BranchSnapshot(
            repoPath: repo,
            branch: branch,
            baseBranch: baseBranch,
            mergeBase: mergeBase,
            mergeBaseShort: mergeBaseShort,
            commits: commits,
            files: files,
            aheadOfRemote: remote.ahead,
            behindRemote: remote.behind,
            remoteTrackingBranch: remote.tracking
        )
    }

    public func fileDiff(
        in repo: URL,
        from mergeBase: String,
        to branch: String,
        path: String,
        oldPath: String? = nil
    ) async throws -> String {
        var args = ["diff", "--no-color", "\(mergeBase)...\(branch)", "--"]
        if let oldPath, oldPath != path {
            args.append(oldPath)
        }
        args.append(path)
        return try await runGit(args, in: repo)
    }

    /// Unified diff for a single commit and path.
    public func commitFileDiff(
        in repo: URL,
        commit: String,
        path: String,
        oldPath: String? = nil
    ) async throws -> String {
        var args = ["show", "--no-color", "--format=", "--find-renames", commit, "--"]
        if let oldPath, oldPath != path {
            args.append(oldPath)
        }
        args.append(path)
        return try await runGit(args, in: repo)
    }

    public func commitChangedFiles(in repo: URL, commit: String) async throws -> [ChangedFile] {
        let nameStatus = try await runGit(
            ["show", "--name-status", "--format=", "--find-renames", commit],
            in: repo
        )
        let numStat = try await runGit(
            ["show", "--numstat", "--format=", "--find-renames", commit],
            in: repo
        )
        return parseChangedFiles(nameStatus: nameStatus, numStat: numStat)
    }

    /// File contents at a revision. Returns `nil` when the path does not exist at that revision.
    public func fileContents(
        in repo: URL,
        revision: String,
        path: String
    ) async throws -> String? {
        let result = try await ProcessRunner.run(
            executable: gitURL,
            arguments: ["show", "\(revision):\(path)"],
            currentDirectory: repo
        )
        if result.status != 0 {
            let err = result.stderrText.lowercased()
            if err.contains("does not exist")
                || err.contains("exists on disk")
                || err.contains("invalid object")
                || err.contains("bad revision")
                || err.contains("path") {
                return nil
            }
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(message.isEmpty ? "git show failed (\(result.status))" : message)
        }
        // Avoid dumping huge binaries into the UI.
        if result.stdout.contains(0) {
            return nil
        }
        return result.stdoutText
    }

    // MARK: - Private

    private func listCommits(in repo: URL, from mergeBase: String, to branch: String) async throws -> [GitCommit] {
        // Exclusive range: commits reachable from branch but not merge-base.
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%ae%x1f%aI%x1f%P%x1e"
        let output = try await runGit(
            ["log", "--format=\(format)", "\(mergeBase)..\(branch)"],
            in: repo
        )

        let records = output.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        return records.compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            let date = iso.date(from: fields[5]) ?? isoBasic.date(from: fields[5]) ?? Date.distantPast
            let parents = fields[6]
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }
            return GitCommit(
                hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                shortHash: fields[1],
                subject: fields[2],
                authorName: fields[3],
                authorEmail: fields[4],
                authoredDate: date,
                parents: parents
            )
        }
    }

    private func listChangedFiles(in repo: URL, from mergeBase: String, to branch: String) async throws -> [ChangedFile] {
        let nameStatus = try await runGit(
            ["diff", "--name-status", "--find-renames", "\(mergeBase)...\(branch)"],
            in: repo
        )
        let numStat = try await runGit(
            ["diff", "--numstat", "--find-renames", "\(mergeBase)...\(branch)"],
            in: repo
        )
        return parseChangedFiles(nameStatus: nameStatus, numStat: numStat)
    }

    private func parseChangedFiles(nameStatus: String, numStat: String) -> [ChangedFile] {
        var stats: [String: (Int, Int)] = [:]
        for line in numStat.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            let path = parts.count >= 4 ? parts[3] : parts[2]
            stats[path] = (additions, deletions)
        }

        var files: [ChangedFile] = []
        for line in nameStatus.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first, !first.isEmpty else { continue }
            let statusCode = String(first.prefix(1))
            let status = FileChangeStatus(rawValue: statusCode) ?? .unknown

            if (status == .renamed || status == .copied), parts.count >= 3 {
                let oldPath = parts[1]
                let newPath = parts[2]
                let pair = stats[newPath] ?? (0, 0)
                files.append(ChangedFile(
                    status: status,
                    path: newPath,
                    oldPath: oldPath,
                    additions: pair.0,
                    deletions: pair.1
                ))
            } else if parts.count >= 2 {
                let path = parts[1]
                let pair = stats[path] ?? (0, 0)
                files.append(ChangedFile(
                    status: status,
                    path: path,
                    additions: pair.0,
                    deletions: pair.1
                ))
            }
        }

        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func remoteTrackingInfo(
        in repo: URL,
        branch: String
    ) async throws -> (tracking: String?, ahead: Int?, behind: Int?) {
        let tracking = (try? await runGit(
            ["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let tracking, !tracking.isEmpty else {
            return (nil, nil, nil)
        }

        let counts = try await runGit(
            ["rev-list", "--left-right", "--count", "\(branch)...\(tracking)"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = counts.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else {
            return (tracking, nil, nil)
        }
        return (tracking, ahead, behind)
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: gitURL,
            arguments: arguments,
            currentDirectory: directory
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(message.isEmpty ? "git \(arguments.joined(separator: " ")) failed (\(result.status))" : message)
        }
        return result.stdoutText
    }
}
