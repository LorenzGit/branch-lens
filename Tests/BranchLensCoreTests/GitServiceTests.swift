import BranchLensCore
import Foundation
import XCTest

final class GitServiceTests: XCTestCase {
    func testStagePathsReportsRequiredLFSFilterFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-lfs-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init")
        let missingCommand = "branch-lens-missing-git-lfs-\(UUID().uuidString)"
        try await run(in: root, "/usr/bin/git", "config", "filter.lfs.process", missingCommand)
        try await run(in: root, "/usr/bin/git", "config", "filter.lfs.required", "true")
        try "*.mp4 filter=lfs -text\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "video\n".write(to: root.appendingPathComponent("clip.mp4"), atomically: true, encoding: .utf8)

        do {
            try await GitService().stagePaths(["clip.mp4"], in: root)
            XCTFail("Staging must fail when the required filter cannot run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(missingCommand), error.localizedDescription)
        }
        let stagedPaths = try await runCapture(in: root, "/usr/bin/git", "ls-files")
        XCTAssertEqual(stagedPaths, "", "A failed LFS filter must not stage the raw asset")
    }

    func testBranchSnapshotShowsOnlyUniqueCommitsAndAggregatedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")

        try "base\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        try await run(in: root, "/usr/bin/git", "checkout", "-b", "feature")
        try "feature work\n".write(to: root.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try "base\nchanged\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "add feature file")

        try "feature work\nmore\n".write(to: root.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "extend feature")

        let git = GitService()
        let snapshot = try await git.loadSnapshot(repo: root, branch: "feature", baseBranch: "main")

        XCTAssertEqual(snapshot.commits.count, 2)
        XCTAssertEqual(snapshot.commits.map(\.subject), ["extend feature", "add feature file"])
        XCTAssertEqual(Set(snapshot.files.map(\.path)), Set(["feature.txt", "readme.txt"]))
        XCTAssertTrue(snapshot.files.contains { $0.path == "feature.txt" && $0.status == .added })
        XCTAssertTrue(snapshot.files.contains { $0.path == "readme.txt" && $0.status == .modified })

        let diff = try await git.fileDiff(
            in: root,
            from: snapshot.mergeBase,
            to: "feature",
            path: "feature.txt"
        )
        // Aggregated branch diff shows the final file as one added blob.
        XCTAssertTrue(diff.contains("+feature work"))
        XCTAssertTrue(diff.contains("+more"))
    }

    func testChangedFilesToWorktreeNetsOverlappingBranchAndLocalEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-net-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")

        try "keep\n".write(to: root.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        try await run(in: root, "/usr/bin/git", "checkout", "-b", "feature")
        // Branch adds 3 lines (analogous to the +35 case).
        try "keep\na\nb\nc\n".write(to: root.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "add lines")

        // Locally remove 1 of the newly added lines (analogous to the −2 case).
        try "keep\na\nc\n".write(to: root.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)

        let git = GitService()
        let snapshot = try await git.loadSnapshot(repo: root, branch: "feature", baseBranch: "main")
        let branchFile = try XCTUnwrap(snapshot.files.first { $0.path == "story.txt" })
        XCTAssertEqual(branchFile.additions, 3)
        XCTAssertEqual(branchFile.deletions, 0)

        let local = try await git.workingTreeStatus(in: root)
        let unstaged = try XCTUnwrap(local.first { $0.path == "story.txt" && $0.area == .unstaged })
        XCTAssertEqual(unstaged.additions, 0)
        XCTAssertEqual(unstaged.deletions, 1)

        let net = try await git.changedFilesToWorktree(in: root, from: snapshot.mergeBase)
        let netFile = try XCTUnwrap(net.first { $0.path == "story.txt" })
        XCTAssertEqual(netFile.additions, 2)
        XCTAssertEqual(netFile.deletions, 0)
    }

    func testLoadSnapshotReportsMissingBranchInsteadOfFatalObjectName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "base\n".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        let git = GitService()
        let mainExists = await git.revisionExists("main", in: root)
        let missingExists = await git.revisionExists("agent/plus-one-gaps-contract", in: root)
        XCTAssertTrue(mainExists)
        XCTAssertFalse(missingExists)

        do {
            _ = try await git.loadSnapshot(
                repo: root,
                branch: "agent/plus-one-gaps-contract",
                baseBranch: "main"
            )
            XCTFail("Expected missing revision")
        } catch let error as GitError {
            XCTAssertTrue(error.isMissingRevision)
            XCTAssertEqual(error.localizedDescription, "Branch “agent/plus-one-gaps-contract” is not in this repository.")
        }
    }

    func testChangedFilesUsesTripleDotLikeGitHubPullRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-pr-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "base\n".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        try await run(in: root, "/usr/bin/git", "checkout", "-b", "feature")
        try "feature\n".write(to: root.appendingPathComponent("pr.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "pr work")

        try await run(in: root, "/usr/bin/git", "checkout", "main")
        try "main extra\n".write(to: root.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "advance main")
        try await run(in: root, "/usr/bin/git", "branch", "origin/main", "main")
        try await run(in: root, "/usr/bin/git", "reset", "--hard", "HEAD~1")
        try await run(in: root, "/usr/bin/git", "checkout", "feature")
        try await run(in: root, "/usr/bin/git", "merge", "origin/main", "-m", "sync origin/main")

        let git = GitService()
        let vsStaleMain = try await git.changedFiles(in: root, from: "main", to: "feature")
        let vsFreshMain = try await git.changedFiles(in: root, from: "origin/main", to: "feature")
        XCTAssertEqual(Set(vsFreshMain.map(\.path)), ["pr.txt"])
        XCTAssertTrue(vsStaleMain.map(\.path).contains("unrelated.txt"))
        XCTAssertGreaterThan(vsStaleMain.count, vsFreshMain.count)

        let snapshot = try await git.loadSnapshot(repo: root, branch: "feature", baseBranch: "main")
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["pr.txt"])
        XCTAssertFalse(snapshot.commits.contains { $0.subject == "advance main" })
        XCTAssertGreaterThan(snapshot.localCompareBehindCount, 0)
        XCTAssertEqual(snapshot.compareTip, "origin/main")
        XCTAssertTrue(snapshot.localCompareCanFastForward)
    }

    func testLoadSnapshotFlagsDivergedLocalCompare() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-diverged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "base\n".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")
        try await run(in: root, "/usr/bin/git", "branch", "origin/main")

        try "local only\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "local main commit")

        try await run(in: root, "/usr/bin/git", "checkout", "origin/main")
        try "remote only\n".write(to: root.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "origin main commit")
        try await run(in: root, "/usr/bin/git", "checkout", "main")

        let snapshot = try await GitService().loadSnapshot(repo: root, branch: "main", baseBranch: "main")
        XCTAssertEqual(snapshot.compareTip, "origin/main")
        XCTAssertGreaterThan(snapshot.compareAheadCount, 0)
        XCTAssertFalse(snapshot.viewingCanFastForward)
        XCTAssertFalse(snapshot.localCompareCanFastForward)
    }

    func testWriteWorkingTreeFileRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "old\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        let git = GitService()
        try await git.writeWorkingTreeFile(in: root, path: "nested/dir/note.txt", contents: "hello\nworld\n")
        let read = try await git.workingTreeFileContents(in: root, path: "nested/dir/note.txt")
        XCTAssertEqual(read, "hello\nworld\n")

        do {
            try await git.writeWorkingTreeFile(in: root, path: "../outside.txt", contents: "nope")
            XCTFail("Expected path escape to fail")
        } catch {
            // expected
        }
    }

    func testLinkedWorktreeLocalChangesSurviveFilterThatCannotWriteCommonGitDir() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-wt-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lfsDir = root.appendingPathComponent(".git/lfs")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lfsDir.path)
            try? FileManager.default.removeItem(at: root)
        }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "hello\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", "note.txt")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        try "node_modules/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".gitignore")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "ignore node_modules")

        try FileManager.default.createDirectory(at: lfsDir, withIntermediateDirectories: true)

        try "*.txt filter=blocked\n".write(
            to: root.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        try await run(
            in: root,
            "/usr/bin/git",
            "config",
            "filter.blocked.clean",
            "cat"
        )
        try await run(in: root, "/usr/bin/git", "config", "filter.blocked.smudge", "cat")
        try await run(in: root, "/usr/bin/git", "config", "filter.blocked.required", "false")
        try await run(in: root, "/usr/bin/git", "add", ".gitattributes")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "add blocking filter")

        let worktree = root.appendingPathComponent("node_modules/.codex-worktrees/topic")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await run(
            in: root,
            "/usr/bin/git",
            "worktree",
            "add",
            worktree.path,
            "-b",
            "topic"
        )
        try await run(
            in: root,
            "/usr/bin/git",
            "config",
            "filter.blocked.clean",
            "sh -c 'touch \"$(git rev-parse --git-common-dir)/lfs/probe\"; echo cannot-access-common-git-dir >&2; exit 1'"
        )
        try await run(in: root, "/usr/bin/git", "config", "filter.blocked.required", "true")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lfsDir.path)

        try "changed\n".write(to: worktree.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: worktree.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)

        let diff = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["diff", "--numstat", "--find-renames"],
            currentDirectory: worktree
        )
        XCTAssertNotEqual(
            diff.status,
            0,
            "Expected git diff to fail when the filter cannot write the common Git dir"
        )
        XCTAssertTrue(
            diff.stderrText.contains("cannot-access-common-git-dir")
                || diff.stderrText.lowercased().contains("filter"),
            diff.stderrText
        )

        let files = try await GitService().workingTreeStatus(in: worktree)
        let paths = Set(files.map(\.path))
        XCTAssertEqual(paths, ["note.txt", "extra.txt"])
        XCTAssertTrue(files.contains { $0.path == "note.txt" && $0.area == .unstaged })
        XCTAssertTrue(files.contains { $0.path == "extra.txt" && $0.status == .added })
    }

    func testRemoteURLsMatchGitHubIdentityAndPreferHeadWorktree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-pr-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "hello\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", "note.txt")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")
        try await run(in: root, "/usr/bin/git", "remote", "add", "origin", "git@github.com:LorenzGit/venus.git")
        try await run(in: root, "/usr/bin/git", "branch", "lorenzgit/topic")

        let worktree = root.appendingPathComponent("node_modules/.codex-worktrees/topic")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await run(in: root, "/usr/bin/git", "worktree", "add", worktree.path, "lorenzgit/topic")

        let git = GitService()
        let remotes = try await git.remoteURLs(in: worktree)
        XCTAssertTrue(GitRemoteIdentity.matchesAny(remotes, owner: "LorenzGit", repo: "venus"))

        let worktrees = try await git.listWorktrees(in: worktree)
        XCTAssertEqual(
            GitRemoteIdentity.preferredWorktree(
                from: worktrees,
                headBranch: "lorenzgit/topic"
            )?.path.standardizedFileURL.path,
            worktree.standardizedFileURL.path
        )
    }

    func testListBranchesIncludesTipAuthor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-author-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Ada Lovelace")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "ada@example.com")
        try "hello\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", "note.txt")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        let branches = try await GitService().listBranches(in: root)
        let main = try XCTUnwrap(branches.first { $0.name == "main" })
        XCTAssertEqual(main.tipAuthor, "Ada Lovelace")
        XCTAssertEqual(main.tipSubject, "initial")
        XCTAssertNotNil(main.shortHash)
    }

    func testListBranchesReportsAheadBehindVersusCompare() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-ahead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "base\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")
        try await run(in: root, "/usr/bin/git", "checkout", "-b", "feature")
        try "feature\n".write(to: root.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "feature work")

        let branches = try await GitService().listBranches(in: root, versus: "main")
        let feature = try XCTUnwrap(branches.first { $0.name == "feature" })
        XCTAssertEqual(feature.aheadOfCompare, 1)
        XCTAssertEqual(feature.behindOfCompare, 0)
        let main = try XCTUnwrap(branches.first { $0.name == "main" })
        XCTAssertEqual(main.aheadOfCompare, 0)
        XCTAssertEqual(main.behindOfCompare, 0)
    }

    func testParsesUpstreamTrackAndAheadBehindAtoms() {
        XCTAssertEqual(GitBranch.parseUpstreamTrack("[ahead 2, behind 6]").ahead, 2)
        XCTAssertEqual(GitBranch.parseUpstreamTrack("[ahead 2, behind 6]").behind, 6)
        XCTAssertTrue(GitBranch.parseUpstreamTrack("[gone]").gone)
        XCTAssertEqual(GitBranch.parseAheadBehind("12 3")?.ahead, 12)
        XCTAssertEqual(GitBranch.parseAheadBehind("12 3")?.behind, 3)
        XCTAssertNil(GitBranch.parseAheadBehind(""))
    }

    func testParseShortStatReadsFilesAndLineCounts() {
        let stats = CommitChangeStats.parseShortStat(
            " 38 files changed, 1271 insertions(+), 260 deletions(-)"
        )
        XCTAssertEqual(stats.fileCount, 38)
        XCTAssertEqual(stats.additions, 1271)
        XCTAssertEqual(stats.deletions, 260)
        let one = CommitChangeStats.parseShortStat(" 1 file changed, 1 insertion(+)")
        XCTAssertEqual(one.fileCount, 1)
        XCTAssertEqual(one.additions, 1)
        XCTAssertEqual(one.deletions, 0)
    }

    func testRangeChangeStatsUsesTripleDotFileCounts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-range-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "base\n".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")
        try await run(in: root, "/usr/bin/git", "checkout", "-b", "feature")
        try "new\n".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        try "base\nchanged\n".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "feature files")

        let stats = try await GitService().rangeChangeStats(in: root, from: "main", to: "feature")
        XCTAssertEqual(stats.fileCount, 2)
        XCTAssertGreaterThan(stats.additions, 0)
    }

    func testListWorktreesKeepsMissingFoldersForPrune() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-missing-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "hello\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", "note.txt")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        let worktree = root.appendingPathComponent("linked")
        try await run(in: root, "/usr/bin/git", "worktree", "add", "-b", "topic", worktree.path)
        try FileManager.default.removeItem(at: worktree)

        let git = GitService()
        let listed = try await git.listWorktrees(in: root)
        XCTAssertEqual(listed.count, 2)
        let linkedPath = worktree.resolvingSymlinksInPath().path
        let missing = try XCTUnwrap(listed.first {
            $0.path.resolvingSymlinksInPath().path == linkedPath
                || $0.path.lastPathComponent == worktree.lastPathComponent
        })
        XCTAssertFalse(missing.folderExists)
        XCTAssertEqual(WorktreeActions.missingCount(listed), 1)
        XCTAssertNil(WorktreeActions.blockedReason(missing, in: listed, currentPath: root, openPaths: []))

        try await git.removeWorktree(missing, in: root)
        let after = try await git.listWorktrees(in: root)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(WorktreeActions.isPrimary(after[0], in: after))
    }

    func testDeleteLocalBranchRefusesProtectedAndOccupied() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")
        try "hello\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", "note.txt")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")
        try await run(in: root, "/usr/bin/git", "branch", "topic")

        let git = GitService()
        do {
            try await git.deleteLocalBranch("main", in: root)
            XCTFail("Expected protected delete to fail")
        } catch let error as GitError {
            XCTAssertTrue(error.localizedDescription.contains("Refusing to delete"))
        }

        try await git.deleteLocalBranch("topic", in: root)
        let names = try await git.listBranches(in: root).map(\.name)
        XCTAssertFalse(names.contains("topic"))
    }

    func testVenusCodexWorktreeShowsAllLocalChanges() async throws {
        let worktree = URL(
            fileURLWithPath: "/Users/lorenzonuvoletta/git/venus/node_modules/.codex-worktrees/test-app-remote-push"
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: worktree.path))

        let files = try await GitService().workingTreeStatus(in: worktree)
        XCTAssertEqual(
            Set(files.map(\.path)),
            [
                "packages/sdk/tests/test-app/README.md",
                "packages/sdk/tests/test-app/rundot/realtime.config.json",
                "packages/sdk/tests/test-app/src/events/handlers-notifications.ts",
                "packages/sdk/tests/test-app/src/sections/section-notifications.ts",
                "packages/sdk/tests/test-app/src/rooms/PushProbeRoom.ts",
                "tests/products/sdk/pom/mobile/sections/NotificationsSection.mobile.ts",
            ]
        )
    }

    func testFastForwardKeepsUnrelatedLocalEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-ff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")

        try "base\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        try await run(in: root, "/usr/bin/git", "checkout", "-b", "incoming")
        try "incoming\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "add incoming")
        try await run(in: root, "/usr/bin/git", "checkout", "main")

        try "local only\n".write(to: root.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        let git = GitService()
        try await git.fastForwardLocalBranch("main", to: "incoming", in: root)

        let head = try await runCapture(in: root, "/usr/bin/git", "rev-parse", "--abbrev-ref", "HEAD")
        XCTAssertEqual(head, "main")
        let local = try String(contentsOf: root.appendingPathComponent("scratch.txt"), encoding: .utf8)
        XCTAssertEqual(local, "local only\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    func testDiscardPathsRestoresTrackedAndDeletesUntracked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-discard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        try await run(in: root, "/usr/bin/git", "config", "user.name", "Test")
        try await run(in: root, "/usr/bin/git", "config", "user.email", "test@example.com")

        try "original\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", ".")
        try await run(in: root, "/usr/bin/git", "commit", "-m", "initial")

        try "dirty\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "scratch\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "staged new\n".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        try await run(in: root, "/usr/bin/git", "add", "added.txt")

        let git = GitService()
        try await git.discardPaths(["tracked.txt", "new.txt", "added.txt"], in: root)

        let restored = try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8)
        XCTAssertEqual(restored, "original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("added.txt").path))
        let leftover = try await git.workingTreeStatus(in: root)
        XCTAssertTrue(leftover.isEmpty)
    }

    func testDiscardPathsRejectsAbsoluteAndEscapingPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-discard-safe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await run(in: root, "/usr/bin/git", "init", "-b", "main")
        let git = GitService()
        do {
            try await git.discardPaths(["/tmp/evil"], in: root)
            XCTFail("Expected absolute path to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Invalid path"))
        }
        do {
            try await git.discardPaths(["../outside.txt"], in: root)
            XCTFail("Expected escaping path to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Refusing to discard"))
        }
    }

    private func runCapture(in directory: URL, _ executable: String, _ args: String...) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: executable),
            arguments: args,
            currentDirectory: directory
        )
        if result.status != 0 {
            XCTFail(result.stderrText)
            throw GitError.commandFailed(result.stderrText)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(in directory: URL, _ executable: String, _ args: String...) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: executable),
            arguments: args,
            currentDirectory: directory
        )
        if result.status != 0 {
            XCTFail(result.stderrText)
            throw GitError.commandFailed(result.stderrText)
        }
    }
}
