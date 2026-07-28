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
