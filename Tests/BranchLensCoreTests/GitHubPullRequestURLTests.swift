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

    func testPrefersWorktreeCheckedOutToHeadBranch() {
        let main = GitWorktree(
            path: URL(fileURLWithPath: "/tmp/venus"),
            head: "aaa",
            branch: "develop",
            isBare: false,
            isDetached: false
        )
        let pr = GitWorktree(
            path: URL(fileURLWithPath: "/tmp/venus/node_modules/.codex-worktrees/topic"),
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
}
