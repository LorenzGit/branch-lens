import BranchLensCore
import XCTest

final class AllChangesFilesTests: XCTestCase {
    func testEmptyViewingKeepsLocalOnlyFiles() {
        let local = [
            WorkingTreeFile(area: .unstaged, status: .modified, path: "a.swift", additions: 2, deletions: 1),
            WorkingTreeFile(area: .unstaged, status: .added, path: "b.swift", additions: 4),
        ]
        let files = AllChangesFiles.viewingPlusLocal(branchFiles: [], workingTreeFiles: local)
        XCTAssertEqual(files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(files.map(\.additions), [2, 4])
    }

    func testKeepsViewingFilesAndAddsLocalOnlyPaths() {
        let branch = [
            ChangedFile(status: .modified, path: "shared.swift", additions: 10, deletions: 2),
            ChangedFile(status: .added, path: "feature.swift", additions: 8),
        ]
        let local = [
            WorkingTreeFile(area: .unstaged, status: .modified, path: "shared.swift", additions: 1, deletions: 1),
            WorkingTreeFile(area: .unstaged, status: .modified, path: "local.swift", additions: 3),
        ]
        let files = AllChangesFiles.viewingPlusLocal(branchFiles: branch, workingTreeFiles: local)
        XCTAssertEqual(files.map(\.path), ["feature.swift", "local.swift", "shared.swift"])
        let shared = files.first { $0.path == "shared.swift" }
        XCTAssertEqual(shared?.additions, 10)
        XCTAssertEqual(files.first { $0.path == "local.swift" }?.additions, 3)
    }

    func testSamePathStagedAndUnstagedBecomesOneRow() {
        let local = [
            WorkingTreeFile(area: .staged, status: .modified, path: "a.swift", additions: 2),
            WorkingTreeFile(area: .unstaged, status: .modified, path: "a.swift", additions: 5, deletions: 1),
        ]
        let files = AllChangesFiles.viewingPlusLocal(branchFiles: [], workingTreeFiles: local)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "a.swift")
    }
}
