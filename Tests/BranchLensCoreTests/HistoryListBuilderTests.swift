import BranchLensCore
import Foundation
import XCTest

final class HistoryListBuilderTests: XCTestCase {
    func testDropsIncomingMergeSideBranchAndMergeCommit() {
        // Newest first: feature fix, merge from develop, then a develop commit.
        let feature = commit("f09", subject: "fix notifications", parents: ["d63"])
        let merge = commit("d63", subject: "Merge branch develop", parents: ["aaa", "cfd"])
        let incoming = commit("cfd", subject: "wait for encoding", parents: ["bbb"])
        let older = commit("aaa", subject: "older feature", parents: ["root"])

        let all = [feature, merge, incoming, older]
        let visible = HistoryListBuilder.currentBranchCommits(
            allRangeCommits: all,
            displayed: [feature, merge, incoming]
        )

        XCTAssertEqual(visible.map(\.hash), ["f09"])
    }

    func testKeepsLinearFirstParentCommits() {
        let newer = commit("c2", subject: "second", parents: ["c1"])
        let older = commit("c1", subject: "first", parents: ["root"])
        let visible = HistoryListBuilder.currentBranchCommits(
            allRangeCommits: [newer, older],
            displayed: [newer, older]
        )
        XCTAssertEqual(visible.map(\.hash), ["c2", "c1"])
    }

    func testGroupsMultipleCommitsForTheSamePullRequest() {
        let newer = commit("c2", subject: "follow-up", parents: ["c1"])
        let older = commit("c1", subject: "start", parents: ["root"])
        let pr = pullRequest(3864, status: "open", title: "notifications")
        let items = HistoryListBuilder.items(
            visibleCommits: [newer, older],
            pullRequests: ["c2": pr, "c1": pr]
        )
        XCTAssertEqual(items.count, 1)
        guard case .pullRequest(let link, let commits) = items[0] else {
            return XCTFail("Expected one PR row")
        }
        XCTAssertEqual(link.number, 3864)
        XCTAssertEqual(commits.map(\.hash), ["c2", "c1"])
    }

    func testLeavesUnrelatedPullRequestsAsSeparateRows() {
        let mine = commit("c2", subject: "mine", parents: ["c1"])
        let other = commit("c1", subject: "theirs", parents: ["root"])
        let items = HistoryListBuilder.items(
            visibleCommits: [mine, other],
            pullRequests: [
                "c2": pullRequest(3864, status: "open"),
                "c1": pullRequest(3863, status: "merged"),
            ]
        )
        XCTAssertEqual(items.count, 2)
        guard case .commit(let first) = items[0], case .commit(let second) = items[1] else {
            return XCTFail("Expected two commit rows")
        }
        XCTAssertEqual(first.hash, "c2")
        XCTAssertEqual(second.hash, "c1")
    }

    func testCommitWithoutPullRequestStaysACommitRow() {
        let only = commit("c1", subject: "wip", parents: ["root"])
        let items = HistoryListBuilder.items(visibleCommits: [only], pullRequests: [:])
        XCTAssertEqual(items, [.commit(only)])
    }

    private func commit(_ hash: String, subject: String, parents: [String]) -> GitCommit {
        GitCommit(
            hash: hash,
            shortHash: String(hash.prefix(7)),
            subject: subject,
            authorName: "Test",
            authorEmail: "test@example.com",
            authoredDate: Date(),
            parents: parents
        )
    }

    private func pullRequest(_ number: Int, status: String, title: String = "PR") -> CommitPullRequestLink {
        CommitPullRequestLink(
            number: number,
            title: title,
            url: "https://example.com/\(number)",
            isDraft: false,
            status: status
        )
    }
}
