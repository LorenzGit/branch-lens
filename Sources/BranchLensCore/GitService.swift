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

    public func listBranches(in repo: URL) async throws -> [GitBranch] {
        let output = try await runGit(
            [
                "for-each-ref",
                "--format=%(refname:short)%00%(committerdate:iso8601-strict)",
                "--sort=refname",
                "refs/heads/",
            ],
            in: repo
        )
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> GitBranch? in
                let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
                guard let namePart = parts.first else { return nil }
                let name = String(namePart).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let dateString = parts.count > 1 ? String(parts[1]) : ""
                return GitBranch(name: name, tipDate: Self.parseGitDate(dateString))
            }
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

    /// Fetch all remotes so local remote-tracking refs are up to date.
    public func fetchRemotes(in repo: URL) async throws {
        _ = try await runGit(["fetch", "--all", "--prune"], in: repo)
    }

    public func commitCount(in repo: URL, from: String, to: String) async throws -> Int {
        let output = try await runGit(
            ["rev-list", "--count", "\(from)..\(to)"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }

    /// Prefer a freshly fetched tip for COMPARE: upstream, then `origin/<branch>`, else local.
    public func resolveFreshTip(for branch: String, in repo: URL) async -> String {
        if let upstream = try? await runGit(
            ["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines),
           !upstream.isEmpty,
           (try? await runGit(["rev-parse", "--verify", upstream], in: repo)) != nil {
            return upstream
        }

        let originTip = "origin/\(branch)"
        if (try? await runGit(["rev-parse", "--verify", originTip], in: repo)) != nil {
            return originTip
        }

        return branch
    }

    public func isWorkingTreeClean(in repo: URL) async throws -> Bool {
        let status = try await runGit(["status", "--porcelain"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty
    }

    /// Checkout `target` if needed, then merge `source` into it.
    public func merge(source: String, into target: String, in repo: URL) async throws {
        let current = try await currentBranch(in: repo)
        if current != target {
            guard try await isWorkingTreeClean(in: repo) else {
                throw GitError.commandFailed(
                    "Working tree has uncommitted changes. Commit or stash before updating “\(target)”."
                )
            }
            _ = try await runGit(["checkout", target], in: repo)
        }
        _ = try await runGit(["merge", "--no-edit", source], in: repo)
    }

    /// Fast-forward a local branch ref to `tip` without switching branches when possible.
    public func fastForwardLocalBranch(_ branch: String, to tip: String, in repo: URL) async throws {
        let branchSHA = try await runGit(["rev-parse", branch], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSHA = try await runGit(["rev-parse", tip], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if branchSHA == tipSHA { return }

        let ancestor = try await ProcessRunner.run(
            executable: gitURL,
            arguments: ["merge-base", "--is-ancestor", branch, tip],
            currentDirectory: repo
        )
        guard ancestor.status == 0 else {
            throw GitError.commandFailed(
                "Cannot fast-forward “\(branch)” to “\(tip)” — histories have diverged."
            )
        }

        let current = try await currentBranch(in: repo)
        if current == branch {
            guard try await isWorkingTreeClean(in: repo) else {
                throw GitError.commandFailed(
                    "Working tree has uncommitted changes. Commit or stash before updating “\(branch)”."
                )
            }
            _ = try await runGit(["merge", "--ff-only", tip], in: repo)
        } else {
            // Update the ref in place so we don't disturb the checked-out feature branch.
            _ = try await runGit(["update-ref", "refs/heads/\(branch)", tipSHA], in: repo)
        }
    }

    public func isAncestor(
        _ maybeAncestor: String,
        of commit: String,
        in repo: URL
    ) async -> Bool {
        let result = try? await ProcessRunner.run(
            executable: gitURL,
            arguments: ["merge-base", "--is-ancestor", maybeAncestor, commit],
            currentDirectory: repo
        )
        return result?.status == 0
    }

    public func revisionsEqual(
        _ lhs: String,
        _ rhs: String,
        in repo: URL
    ) async -> Bool {
        let left = (try? await runGit(["rev-parse", lhs], in: repo))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = (try? await runGit(["rev-parse", rhs], in: repo))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let left, let right, !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    public func commitDetails(
        for hash: String,
        in repo: URL
    ) async throws -> GitCommit? {
        try await listCommits(in: repo, range: "-1 \(hash)").first
    }

    /// Commits that this branch contributed into `compareTip` when the branch tip is
    /// already fully contained in COMPARE (typical after a merged PR).
    public func commitsMergedIntoCompare(
        branch: String,
        compareTip: String,
        in repo: URL
    ) async throws -> [GitCommit] {
        guard await isAncestor(branch, of: compareTip, in: repo) else { return [] }

        // Prefer commits brought in by the merge commit on the path to COMPARE.
        let mergeHash = try await runGit(
            [
                "log",
                "--merges",
                "--ancestry-path",
                "--format=%H",
                "-1",
                "\(branch)..\(compareTip)",
            ],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if !mergeHash.isEmpty {
            let parentsOutput = try await runGit(
                ["rev-parse", "\(mergeHash)^1", "\(mergeHash)^2"],
                in: repo
            )
            let parents = parentsOutput
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if parents.count >= 2 {
                let merged = try await listCommits(in: repo, range: "\(parents[0])..\(parents[1])")
                if !merged.isEmpty { return merged }
            }
        }

        // Squash / fast-forward fallback: at least show the branch tip.
        return try await listCommits(in: repo, range: "-1 \(branch)")
    }

    public func revisionExists(_ revision: String, in repo: URL) async -> Bool {
        guard !revision.isEmpty else { return false }
        return (try? await runGit(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            in: repo
        )) != nil
    }

    public func loadSnapshot(
        repo: URL,
        branch: String,
        baseBranch: String
    ) async throws -> BranchSnapshot {
        if await !revisionExists(branch, in: repo) {
            throw GitError.missingRevision(branch)
        }
        if await !revisionExists(baseBranch, in: repo) {
            throw GitError.missingRevision(baseBranch)
        }

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
        // Behind-COMPARE uses the freshest tip (usually origin/<compare> after fetch),
        // not a possibly stale local compare branch.
        let compareTip = await resolveFreshTip(for: baseBranch, in: repo)
        let compareAheadCount = try await commitCount(in: repo, from: branch, to: compareTip)
        let localCompareBehindCount: Int
        let staleCompareInheritedCommitCount: Int
        if compareTip == baseBranch {
            localCompareBehindCount = 0
            staleCompareInheritedCommitCount = 0
        } else {
            localCompareBehindCount = (try? await commitCount(in: repo, from: baseBranch, to: compareTip)) ?? 0
            // Commits shown via local COMPARE that are already on the fresh tip (noise in History).
            if localCompareBehindCount > 0 {
                let uniqueVsCompareTip = (try? await commitCount(in: repo, from: compareTip, to: branch)) ?? commits.count
                staleCompareInheritedCommitCount = max(0, commits.count - uniqueVsCompareTip)
            } else {
                staleCompareInheritedCommitCount = 0
            }
        }
        let remote = try await remoteTrackingInfo(in: repo, branch: branch)

        return BranchSnapshot(
            repoPath: repo,
            branch: branch,
            baseBranch: baseBranch,
            mergeBase: mergeBase,
            mergeBaseShort: mergeBaseShort,
            commits: commits,
            files: files,
            compareAheadCount: compareAheadCount,
            compareTip: compareTip,
            localCompareBehindCount: localCompareBehindCount,
            staleCompareInheritedCommitCount: staleCompareInheritedCommitCount,
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

    /// Files / insertions / deletions for a single commit.
    public func commitChangeStats(in repo: URL, commit: String) async throws -> CommitChangeStats {
        let numStat = try await runGit(
            ["show", "--numstat", "--format=", "--find-renames", commit],
            in: repo
        )
        var fileCount = 0
        var additions = 0
        var deletions = 0
        for line in numStat.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            fileCount += 1
            additions += Int(parts[0]) ?? 0
            deletions += Int(parts[1]) ?? 0
        }
        return CommitChangeStats(fileCount: fileCount, additions: additions, deletions: deletions)
    }

    /// History of commits that touched `path` (follows renames).
    public func fileHistory(
        in repo: URL,
        path: String,
        limit: Int = 150
    ) async throws -> [FileLogEntry] {
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%ae%x1f%aI%x1f%D%x1e"
        let output = try await runGit(
            ["log", "--follow", "--format=\(format)", "-\(limit)", "--", path],
            in: repo
        )
        return parseFileLog(output)
    }

    /// Local + remote branch names that contain the commit (capped for UI).
    public func branchesContaining(
        in repo: URL,
        commit: String,
        limit: Int = 12
    ) async throws -> [String] {
        let output = try await runGit(
            ["branch", "-a", "--contains", commit, "--format=%(refname:short)"],
            in: repo
        )
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0 }
    }

    /// Origin remote URL if configured.
    public func remoteURL(in repo: URL, name: String = "origin") async throws -> String? {
        let output = (try? await runGit(["remote", "get-url", name], in: repo))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }

    /// Staged + unstaged (+ untracked) files in the working tree.
    public func workingTreeStatus(in repo: URL) async throws -> [WorkingTreeFile] {
        let porcelain = try await runGit(["status", "--porcelain=1", "-uall"], in: repo)
        let stagedNum = try await runGit(["diff", "--cached", "--numstat", "--find-renames"], in: repo)
        let unstagedNum = try await runGit(["diff", "--numstat", "--find-renames"], in: repo)
        let stagedStats = parseNumStat(stagedNum)
        let unstagedStats = parseNumStat(unstagedNum)

        var files: [WorkingTreeFile] = []
        for line in porcelain.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.count >= 3 else { continue }
            let x = raw[raw.startIndex]
            let y = raw[raw.index(raw.startIndex, offsetBy: 1)]
            let rest = String(raw.dropFirst(3))

            if x == "?" && y == "?" {
                let path = unescapeStatusPath(rest)
                files.append(WorkingTreeFile(
                    area: .unstaged,
                    status: .added,
                    path: path,
                    additions: stagedStats[path]?.0 ?? 0,
                    deletions: 0
                ))
                continue
            }

            let (path, oldPath) = parseStatusPath(rest)
            if x != " " && x != "?" {
                let status = FileChangeStatus(rawValue: String(x)) ?? .modified
                let stats = stagedStats[path] ?? (0, 0)
                files.append(WorkingTreeFile(
                    area: .staged,
                    status: status == .unknown ? .modified : status,
                    path: path,
                    oldPath: oldPath,
                    additions: stats.0,
                    deletions: stats.1
                ))
            }
            if y != " " && y != "?" {
                let status = FileChangeStatus(rawValue: String(y)) ?? .modified
                let stats = unstagedStats[path] ?? (0, 0)
                files.append(WorkingTreeFile(
                    area: .unstaged,
                    status: status == .unknown ? .modified : status,
                    path: path,
                    oldPath: oldPath,
                    additions: stats.0,
                    deletions: stats.1
                ))
            }
        }

        return files.sorted { lhs, rhs in
            if lhs.area != rhs.area {
                return lhs.area == .staged
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    public func stagedDiff(in repo: URL, path: String, oldPath: String? = nil) async throws -> String {
        var args = ["diff", "--cached", "--no-color", "--find-renames", "--"]
        if let oldPath, oldPath != path { args.append(oldPath) }
        args.append(path)
        return try await runGit(args, in: repo)
    }

    public func unstagedDiff(in repo: URL, path: String, oldPath: String? = nil) async throws -> String {
        // Untracked files have no diff against the index — synthesize from file contents later.
        var args = ["diff", "--no-color", "--find-renames", "--"]
        if let oldPath, oldPath != path { args.append(oldPath) }
        args.append(path)
        return try await runGit(args, in: repo)
    }

    /// Stage paths in the index (`git add -- …`). Works for modified, deleted, and untracked.
    public func stagePaths(_ paths: [String], in repo: URL) async throws {
        let cleaned = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        _ = try await runGit(["add", "--"] + cleaned, in: repo)
    }

    /// Unstage paths (`git restore --staged -- …`).
    public func unstagePaths(_ paths: [String], in repo: URL) async throws {
        let cleaned = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        _ = try await runGit(["restore", "--staged", "--"] + cleaned, in: repo)
    }

    /// Create a commit from the current index with the given message.
    public func commit(message: String, in repo: URL) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitError.commandFailed("Commit message cannot be empty.")
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-commit-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temp) }
        try trimmed.data(using: .utf8)?.write(to: temp)
        _ = try await runGit(["commit", "-F", temp.path], in: repo)
    }

    /// Push the current branch. Sets upstream to `origin/<branch>` when none is configured.
    public func pushCurrentBranch(in repo: URL, branch: String) async throws {
        let tracking = try? await runGit(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if let tracking, !tracking.isEmpty {
            _ = try await runGit(["push"], in: repo)
        } else {
            _ = try await runGit(["push", "-u", "origin", branch], in: repo)
        }
    }

    /// Apply a unified diff to the index. `reverse: true` unstages the hunk.
    public func applyPatchToIndex(
        _ patch: String,
        in repo: URL,
        reverse: Bool
    ) async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: temp) }
        try patch.data(using: .utf8)?.write(to: temp)

        var args = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        args.append(contentsOf: ["--", temp.path])

        let result = try await ProcessRunner.run(
            executable: gitURL,
            arguments: args,
            currentDirectory: repo
        )
        if result.status != 0 {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty
                    ? "git apply --cached failed (\(result.status))"
                    : message
            )
        }
    }

    /// Diff from a revision (e.g. merge-base) through the working tree (includes commits + local edits).
    public func worktreeDiff(
        in repo: URL,
        from revision: String,
        path: String,
        oldPath: String? = nil
    ) async throws -> String {
        var args = ["diff", "--no-color", "--find-renames", revision, "--"]
        if let oldPath, oldPath != path { args.append(oldPath) }
        args.append(path)
        return try await runGit(args, in: repo)
    }

    /// Net file list from `revision` to the working tree (branch commits + staged/unstaged),
    /// with additions/deletions that cancel overlapping edits (unlike summing separate diffs).
    public func changedFilesToWorktree(in repo: URL, from revision: String) async throws -> [ChangedFile] {
        let nameStatus = try await runGit(
            ["diff", "--name-status", "--find-renames", revision],
            in: repo
        )
        let numStat = try await runGit(
            ["diff", "--numstat", "--find-renames", revision],
            in: repo
        )
        var files = parseChangedFiles(nameStatus: nameStatus, numStat: numStat)
        let tracked = Set(files.map(\.path))

        let untrackedOutput = try await runGit(
            ["ls-files", "--others", "--exclude-standard"],
            in: repo
        )
        for path in untrackedOutput.split(whereSeparator: \.isNewline).map(String.init) {
            guard !path.isEmpty, !tracked.contains(path) else { continue }
            let additions = Self.lineCount(ofFileAt: repo.appendingPathComponent(path))
            files.append(ChangedFile(
                status: .added,
                path: path,
                additions: additions,
                deletions: 0
            ))
        }

        return files.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private static func lineCount(ofFileAt url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), !data.contains(0) else { return 0 }
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        if text.isEmpty { return 0 }
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        // Trailing newline does not add an extra empty line for numstat-style counts.
        return text.hasSuffix("\n") ? max(count - 1, 0) : count
    }

    /// Blob currently in the index (`:path`).
    public func indexFileContents(in repo: URL, path: String) async throws -> String? {
        guard let data = try await indexFileData(in: repo, path: path) else { return nil }
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Raw index blob bytes (`:path`).
    public func indexFileData(in repo: URL, path: String) async throws -> Data? {
        let result = try await ProcessRunner.run(
            executable: gitURL,
            arguments: ["show", ":\(path)"],
            currentDirectory: repo
        )
        if result.status != 0 { return nil }
        return Self.cappedBlob(result.stdout)
    }

    /// On-disk working tree file contents.
    public func workingTreeFileContents(in repo: URL, path: String) async throws -> String? {
        guard let data = try await workingTreeFileData(in: repo, path: path) else { return nil }
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// On-disk working tree file bytes.
    public func workingTreeFileData(in repo: URL, path: String) async throws -> Data? {
        let url = repo.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return Self.cappedBlob(data)
    }

    /// Write UTF-8 text to a working-tree path (creates intermediate directories).
    public func writeWorkingTreeFile(in repo: URL, path: String, contents: String) async throws {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("/"), !cleaned.contains("\0") else {
            throw GitError.commandFailed("Invalid path for write.")
        }
        // Refuse path escape outside the repo.
        let url = repo.appendingPathComponent(cleaned).standardizedFileURL
        let repoPath = repo.standardizedFileURL.path
        guard url.path == repoPath || url.path.hasPrefix(repoPath + "/") else {
            throw GitError.commandFailed("Refusing to write outside the repository.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = contents.data(using: .utf8) else {
            throw GitError.commandFailed("Could not encode file as UTF-8.")
        }
        try data.write(to: url, options: .atomic)
    }

    public func listWorktrees(in repo: URL) async throws -> [GitWorktree] {
        let output = try await runGit(["worktree", "list", "--porcelain"], in: repo)
        var worktrees: [GitWorktree] = []
        var path: URL?
        var head = ""
        var branch: String?
        var isBare = false
        var isDetached = false

        func flush() {
            guard let path else { return }
            worktrees.append(GitWorktree(
                path: path,
                head: head,
                branch: branch,
                isBare: isBare,
                isDetached: isDetached
            ))
        }

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("worktree ") {
                flush()
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
                head = ""
                branch = nil
                isBare = false
                isDetached = false
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            }
        }
        flush()
        return worktrees
    }

    /// File contents at a revision. Returns `nil` when the path does not exist at that revision.
    public func fileContents(
        in repo: URL,
        revision: String,
        path: String
    ) async throws -> String? {
        guard let data = try await fileData(in: repo, revision: revision, path: path) else { return nil }
        // Avoid dumping huge binaries into the UI as text.
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Raw file bytes at a revision. Returns `nil` when missing.
    public func fileData(
        in repo: URL,
        revision: String,
        path: String
    ) async throws -> Data? {
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
        return Self.cappedBlob(result.stdout)
    }

    private static let maxBlobBytes = 25 * 1024 * 1024

    private static func cappedBlob(_ data: Data) -> Data? {
        guard data.count <= maxBlobBytes else { return nil }
        return data
    }

    /// Newest-first chronological log of `branch` (not limited to COMPARE…BRANCH).
    /// Use `skip` for progressive infinite loading without a pagination UI.
    public func listCommitsChronological(
        in repo: URL,
        branch: String,
        limit: Int = 200,
        skip: Int = 0
    ) async throws -> [GitCommit] {
        let capped = max(1, min(limit, 500))
        let skipped = max(0, skip)
        var range = "--date-order -\(capped)"
        if skipped > 0 {
            range += " --skip=\(skipped)"
        }
        range += " \(branch)"
        return try await listCommits(in: repo, range: range)
    }

    // MARK: - Private

    private func listCommits(in repo: URL, from mergeBase: String, to branch: String) async throws -> [GitCommit] {
        // Exclusive range: commits reachable from branch but not merge-base.
        try await listCommits(in: repo, range: "\(mergeBase)..\(branch)")
    }

    private func listCommits(in repo: URL, range: String) async throws -> [GitCommit] {
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%ae%x1f%aI%x1f%P%x1e"
        // `range` may include flags like "-1 branch" for tip-only fallback.
        let args = ["log", "--format=\(format)"] + range.split(separator: " ").map(String.init)
        let output = try await runGit(args, in: repo)

        let records = output.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        return records.compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            let date = Self.parseGitDate(fields[5])
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

    private func parseFileLog(_ output: String) -> [FileLogEntry] {
        let records = output.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        return records.compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            return FileLogEntry(
                hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                shortHash: fields[1],
                subject: fields[2],
                authorName: fields[3],
                authorEmail: fields[4],
                authoredDate: Self.parseGitDate(fields[5]),
                decorations: fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func parseGitDate(_ value: String) -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        return iso.date(from: value) ?? isoBasic.date(from: value) ?? Date.distantPast
    }

    /// Triple-dot file list (`from...to`), same as GitHub’s PR “files changed”.
    public func changedFiles(in repo: URL, from: String, to: String) async throws -> [ChangedFile] {
        try await listChangedFiles(in: repo, from: from, to: to)
    }

    public func mergeBase(of a: String, and b: String, in repo: URL) async throws -> String {
        try await runGit(["merge-base", a, b], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let stats = parseNumStat(numStat)

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

    private func parseNumStat(_ numStat: String) -> [String: (Int, Int)] {
        var stats: [String: (Int, Int)] = [:]
        for line in numStat.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            let path = parts.count >= 4 ? parts[3] : parts[2]
            stats[path] = (additions, deletions)
        }
        return stats
    }

    private func parseStatusPath(_ rest: String) -> (path: String, oldPath: String?) {
        if let range = rest.range(of: " -> ") {
            let oldPath = unescapeStatusPath(String(rest[..<range.lowerBound]))
            let path = unescapeStatusPath(String(rest[range.upperBound...]))
            return (path, oldPath)
        }
        return (unescapeStatusPath(rest), nil)
    }

    private func unescapeStatusPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private func remoteTrackingInfo(
        in repo: URL,
        branch: String
    ) async throws -> (tracking: String?, ahead: Int?, behind: Int?) {
        let upstream = (try? await runGit(
            ["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"],
            in: repo
        ).trimmingCharacters(in: .whitespacesAndNewlines))
        let originTip = "origin/\(branch)"
        let tracking: String?
        if let upstream, !upstream.isEmpty {
            tracking = upstream
        } else if (try? await runGit(["rev-parse", "--verify", originTip], in: repo)) != nil {
            tracking = originTip
        } else {
            // No remote counterpart yet — treat all local commits as unpushed if the branch exists.
            return (nil, nil, nil)
        }

        guard let tracking else { return (nil, nil, nil) }

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
