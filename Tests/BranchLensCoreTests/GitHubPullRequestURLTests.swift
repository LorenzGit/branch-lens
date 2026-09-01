import BranchLensCore
import XCTest

final class GitHubPullRequestURLTests: XCTestCase {
    func testParsesCommonGitHubPullRequestLinks() {
        let expected = GitHubPullRequestRef(
            host: "github.com",
            owner: "LorenzGit",
            repo: "venus",
            number: 3946
        )
        let samples = [
            "https://github.com/LorenzGit/venus/pull/3946",
            "https://www.github.com/LorenzGit/venus/pull/3946/files",
            "https://github.com/LorenzGit/venus/pull/3946#discussion_r1",
            "github.com/LorenzGit/venus/pull/3946",
            "  https://github.com/LorenzGit/venus/pulls/3946/commits  ",
        ]
        for sample in samples {
            XCTAssertEqual(GitHubPullRequestURL.parse(sample), expected, sample)
        }
    }

    func testRejectsNonPullRequestURLs() {
        XCTAssertNil(GitHubPullRequestURL.parse(""))
        XCTAssertNil(GitHubPullRequestURL.parse("https://github.com/LorenzGit/venus"))
        XCTAssertNil(GitHubPullRequestURL.parse("https://github.com/LorenzGit/venus/issues/3946"))
        XCTAssertNil(GitHubPullRequestURL.parse("https://gitlab.com/LorenzGit/venus/pull/3946"))
        XCTAssertNil(GitHubPullRequestURL.parse("https://github.com/LorenzGit/venus/pull/0"))
    }

    func testMatchesGitHubRemoteURLs() {
        let remotes = [
            "git@github.com:LorenzGit/venus.git",
            "https://github.com/LorenzGit/venus.git",
            "https://github.com/lorenzgit/venus",
            "ssh://git@github.com/LorenzGit/venus.git",
        ]
        for remote in remotes {
            XCTAssertEqual(
                GitRemoteIdentity.nameWithOwner(from: remote)?.lowercased(),
                "lorenzgit/venus",
                remote
            )
            XCTAssertTrue(GitRemoteIdentity.matches(remote, owner: "lorenzgit", repo: "venus"), remote)
        }
        XCTAssertFalse(GitRemoteIdentity.matches("git@github.com:Other/venus.git", owner: "LorenzGit", repo: "venus"))
        XCTAssertTrue(GitRemoteIdentity.matchesAny(remotes, owner: "LorenzGit", repo: "venus"))
    }

    func testPrefersWorktreeCheckedOutToHeadBranch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-wt-pick-\(UUID().uuidString)", isDirectory: true)
        let mainPath = root.appendingPathComponent("venus", isDirectory: true)
        let prPath = root.appendingPathComponent("venus/node_modules/.codex-worktrees/topic", isDirectory: true)
        try FileManager.default.createDirectory(at: prPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = GitWorktree(
            path: mainPath,
            head: "aaa",
            branch: "develop",
            isBare: false,
            isDetached: false
        )
        let pr = GitWorktree(
            path: prPath,
            head: "bbb",
            branch: "lorenzgit/topic",
            isBare: false,
            isDetached: false
        )
        XCTAssertEqual(
            GitRemoteIdentity.preferredWorktree(
                from: [main, pr],
                headBranch: "lorenzgit/topic"
            )?.path.path,
            pr.path.path
        )
        XCTAssertNil(
            GitRemoteIdentity.preferredWorktree(from: [main], headBranch: "lorenzgit/topic")
        )
        XCTAssertEqual(
            GitRemoteIdentity.fallbackWorktree(from: [main, pr])?.path.path,
            main.path.path
        )
    }

    func testRecoversLiveCheckoutWhenLinkedWorktreeFolderIsGone() throws {
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-recover-live-\(UUID().uuidString)/choices-h5", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: live.deletingLastPathComponent()) }

        let dead = URL(fileURLWithPath: "/tmp/missing-worktrees/0afd/choices-h5")
        XCTAssertEqual(
            GitRemoteIdentity.recoverLiveRepository(from: dead, knownPaths: [live])?.path,
            live.path
        )
        XCTAssertNil(
            GitRemoteIdentity.recoverLiveRepository(
                from: dead,
                knownPaths: [URL(fileURLWithPath: "/tmp/does-not-exist/choices-h5")]
            )
        )
    }
}
