@testable import BranchLens
import BranchLensCore
import Foundation
import XCTest

final class DiscardConfirmationTests: XCTestCase {
    @MainActor
    func testConfirmedDiscardSurvivesDialogDismissal() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)

        let session = RepoSession()
        session.repoPath = root
        session.changeScope = .unstaged
        await session.reloadWorkingTree()
        session.requestDiscard(session.unstagedWorkingTreeFiles.map(\.asChangedFile))
        let confirmed = try XCTUnwrap(session.pendingLocalDiscard)

        // SwiftUI dismisses the dialog before the button's async Task executes.
        session.dismissLocalDiscard()
        await session.confirmLocalDiscard(confirmed)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        XCTAssertTrue(session.workingTreeFiles.isEmpty)
        XCTAssertEqual(session.statusMessage, "Discarded 1 file.")
    }

    @MainActor
    func testConfirmedBulkDiscardKeepsCapturedSelection() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        let scratch = root.appendingPathComponent("scratch.txt")
        let unrelated = root.appendingPathComponent("keep.txt")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        try "scratch\n".write(to: scratch, atomically: true, encoding: .utf8)
        try "keep\n".write(to: unrelated, atomically: true, encoding: .utf8)
        let session = RepoSession()
        session.repoPath = root
        await session.reloadWorkingTree()
        session.requestDiscard(session.unstagedWorkingTreeFiles
            .filter { $0.path != "keep.txt" }.map(\.asChangedFile))
        let confirmed = try XCTUnwrap(session.pendingLocalDiscard)
        session.dismissLocalDiscard()

        await session.confirmLocalDiscard(confirmed)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep\n")
        XCTAssertEqual(session.statusMessage, "Discarded 2 files.")
    }

    @MainActor
    func testCancellingDiscardLeavesFileUntouched() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        let session = RepoSession()
        session.repoPath = root
        await session.reloadWorkingTree()
        session.requestDiscard(session.unstagedWorkingTreeFiles.map(\.asChangedFile))

        session.dismissLocalDiscard()

        XCTAssertNil(session.pendingLocalDiscard)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "modified\n")
        XCTAssertNil(session.statusMessage)
    }

    @MainActor
    func testFailedDiscardPresentsGitError() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        let session = RepoSession()
        session.repoPath = root
        await session.reloadWorkingTree()
        session.requestDiscard(session.unstagedWorkingTreeFiles.map(\.asChangedFile))
        let confirmed = try XCTUnwrap(session.pendingLocalDiscard)
        session.dismissLocalDiscard()
        try Data().write(to: root.appendingPathComponent(".git/index.lock"))

        await session.confirmLocalDiscard(confirmed)

        XCTAssertEqual(session.localChangeFailure?.title, "Couldn’t discard changes")
        XCTAssertTrue(session.localChangeFailure?.message.contains("index.lock") == true)
        XCTAssertNil(session.statusMessage)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "modified\n")
    }

    private func makeRepository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-confirm-discard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], in: root)
        try await git(["config", "user.name", "Test"], in: root)
        try await git(["config", "user.email", "test@example.com"], in: root)
        try "original\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "note.txt"], in: root)
        try await git(["commit", "-m", "initial"], in: root)
        return root
    }

    private func git(_ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: directory
        )
        guard result.status == 0 else { throw GitError.commandFailed(result.stderrText) }
    }
}
