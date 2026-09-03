import BranchLensCore
import Foundation
import XCTest

final class BranchUpdatePlannerTests: XCTestCase {
    func testMergeWhenViewingIsBehindCompareTip() {
        let action = BranchUpdatePlanner.action(
            viewing: "feature",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 12,
            localCompareBehind: 45,
            checkedOutBranch: "feature",
            hasLocalChanges: false,
            viewingOccupiedBy: nil,
            compareOccupiedBy: nil
        )
        XCTAssertEqual(action?.kind, .mergeIntoViewing)
        XCTAssertEqual(action?.title, "Merge 12")
        XCTAssertTrue(action?.isPrimary ?? false)
        XCTAssertTrue(action?.isEnabled ?? false)
    }

    func testBlocksMergeWhenViewingIsOccupiedElsewhere() {
        let action = BranchUpdatePlanner.action(
            viewing: "feature",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 3,
            localCompareBehind: 0,
            checkedOutBranch: "main",
            hasLocalChanges: false,
            viewingOccupiedBy: "7159/choices-h5",
            compareOccupiedBy: nil
        )
        XCTAssertEqual(action?.kind, .mergeIntoViewing)
        XCTAssertEqual(
            action?.blockedReason,
            "feature is checked out in 7159/choices-h5. Switch to that worktree to merge."
        )
        XCTAssertFalse(action?.isEnabled ?? true)
    }

    func testBlocksMergeWhenCheckoutWouldBeNeededAndTreeIsDirty() {
        let action = BranchUpdatePlanner.action(
            viewing: "feature",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 2,
            localCompareBehind: 0,
            checkedOutBranch: "other",
            hasLocalChanges: true,
            viewingOccupiedBy: nil,
            compareOccupiedBy: nil
        )
        XCTAssertEqual(
            action?.blockedReason,
            "This folder has uncommitted changes, so BranchLens can’t check out feature to merge."
        )
    }

    func testFastForwardWhenViewingIsTheCompareBranch() {
        let action = BranchUpdatePlanner.action(
            viewing: "main",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 4,
            localCompareBehind: 4,
            checkedOutBranch: "main",
            hasLocalChanges: false,
            viewingOccupiedBy: nil,
            compareOccupiedBy: nil
        )
        XCTAssertEqual(action?.kind, .fastForwardViewing)
        XCTAssertTrue(action?.isPrimary ?? false)
    }

    func testRefreshLocalCompareWhenViewingAlreadyIncludesTip() {
        let action = BranchUpdatePlanner.action(
            viewing: "feature",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 0,
            localCompareBehind: 45,
            checkedOutBranch: "feature",
            hasLocalChanges: false,
            viewingOccupiedBy: nil,
            compareOccupiedBy: nil
        )
        XCTAssertEqual(action?.kind, .refreshLocalCompare)
        XCTAssertEqual(action?.title, "Refresh main (−45)")
        XCTAssertFalse(action?.isPrimary ?? true)
        XCTAssertTrue(action?.help.contains("does not change feature") ?? false)
    }

    func testBlocksRefreshWhenLocalCompareIsOccupied() {
        let action = BranchUpdatePlanner.action(
            viewing: "feature",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 0,
            localCompareBehind: 8,
            checkedOutBranch: "feature",
            hasLocalChanges: false,
            viewingOccupiedBy: nil,
            compareOccupiedBy: "choices-h5"
        )
        XCTAssertEqual(action?.blockedReason, "Local main is checked out in choices-h5.")
        XCTAssertFalse(action?.isEnabled ?? true)
    }

    func testNoActionWhenEverythingIsCurrent() {
        XCTAssertNil(
            BranchUpdatePlanner.action(
                viewing: "feature",
                compare: "main",
                compareTip: "origin/main",
                viewingBehind: 0,
                localCompareBehind: 0,
                checkedOutBranch: "feature",
                hasLocalChanges: false,
                viewingOccupiedBy: nil,
                compareOccupiedBy: nil
            )
        )
    }

    func testProtectedBranchesCannotBeDeleted() {
        XCTAssertEqual(BranchDeleteRules.blockedReason(name: "main", occupiedBy: nil), "Protected branch")
        XCTAssertEqual(BranchDeleteRules.blockedReason(name: "master", occupiedBy: nil), "Protected branch")
        XCTAssertEqual(
            BranchDeleteRules.blockedReason(name: "topic", occupiedBy: "7159/choices-h5"),
            "Checked out in 7159/choices-h5"
        )
        XCTAssertNil(BranchDeleteRules.blockedReason(name: "topic", occupiedBy: nil))
    }

    func testWorktreeRemoveRules() {
        let primary = GitWorktree(
            path: URL(fileURLWithPath: "/tmp/repo"),
            head: "abc",
            branch: "main",
            isBare: false,
            isDetached: false
        )
        let linked = GitWorktree(
            path: URL(fileURLWithPath: "/tmp/.codex/worktrees/7159/repo"),
            head: "def",
            branch: "feature",
            isBare: false,
            isDetached: false
        )
        let all = [primary, linked]

        XCTAssertTrue(WorktreeActions.isPrimary(primary, in: all))
        XCTAssertFalse(WorktreeActions.isPrimary(linked, in: all))
        XCTAssertEqual(
            WorktreeActions.blockedReason(primary, in: all, currentPath: linked.path, openPaths: []),
            "The primary clone can’t be removed."
        )
        XCTAssertEqual(
            WorktreeActions.blockedReason(linked, in: all, currentPath: linked.path, openPaths: []),
            "This is the folder this tab is using."
        )
        XCTAssertEqual(
            WorktreeActions.blockedReason(
                linked,
                in: all,
                currentPath: primary.path,
                openPaths: [linked.path.standardizedFileURL.path]
            ),
            "This folder is open in another tab."
        )
        XCTAssertNil(
            WorktreeActions.blockedReason(linked, in: all, currentPath: primary.path, openPaths: [])
        )
    }

    func testBlocksSameBranchUpdateWhenOccupiedElsewhere() {
        let action = BranchUpdatePlanner.action(
            viewing: "main",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 4,
            localCompareBehind: 4,
            checkedOutBranch: "feature",
            hasLocalChanges: false,
            viewingOccupiedBy: "choices-h5",
            compareOccupiedBy: nil
        )
        XCTAssertEqual(action?.kind, .fastForwardViewing)
        XCTAssertEqual(action?.blockedReason, "main is checked out in choices-h5.")
        XCTAssertFalse(action?.isEnabled ?? true)
    }

    func testDivergedViewingCompareBecomesAMerge() {
        let action = BranchUpdatePlanner.action(
            viewing: "main",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 4,
            localCompareBehind: 4,
            checkedOutBranch: "main",
            hasLocalChanges: false,
            viewingOccupiedBy: nil,
            compareOccupiedBy: nil,
            viewingCanFastForward: false
        )
        XCTAssertEqual(action?.kind, .mergeIntoViewing)
        XCTAssertEqual(action?.title, "Merge origin/main")
        XCTAssertTrue(action?.isEnabled ?? false)
        XCTAssertTrue(action?.help.contains("diverged") ?? false)
    }

    func testBlocksRefreshWhenLocalCompareHasDiverged() {
        let action = BranchUpdatePlanner.action(
            viewing: "feature",
            compare: "main",
            compareTip: "origin/main",
            viewingBehind: 0,
            localCompareBehind: 8,
            checkedOutBranch: "feature",
            hasLocalChanges: false,
            viewingOccupiedBy: nil,
            compareOccupiedBy: nil,
            localCompareCanFastForward: false
        )
        XCTAssertEqual(action?.blockedReason, "Local main and origin/main have diverged.")
        XCTAssertFalse(action?.isEnabled ?? true)
    }

    func testCompareOptionsStayAShortBaseList() {
        XCTAssertEqual(
            CompareBranchOptions.bases(
                from: ["feature", "main", "develop", "release/1.2", "topic"],
                current: "main"
            ),
            ["main", "develop", "release/1.2"]
        )
        XCTAssertEqual(
            CompareBranchOptions.bases(from: ["feature", "topic"], current: "feature"),
            ["feature"]
        )
        XCTAssertEqual(
            CompareBranchOptions.bases(from: ["integration", "topic"], current: ""),
            ["integration", "topic"]
        )
    }
}