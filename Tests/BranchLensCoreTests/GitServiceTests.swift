import BranchLensCore
import Foundation
import XCTest

final class GitServiceTests: XCTestCase {
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
