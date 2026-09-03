import Foundation

public struct BranchUpdateAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mergeIntoViewing
        case fastForwardViewing
        case refreshLocalCompare
    }

    public let kind: Kind
    public let title: String
    public let help: String
    public let blockedReason: String?
    public let isPrimary: Bool

    public init(
        kind: Kind,
        title: String,
        help: String,
        blockedReason: String?,
        isPrimary: Bool
    ) {
        self.kind = kind
        self.title = title
        self.help = help
        self.blockedReason = blockedReason
        self.isPrimary = isPrimary
    }

    public var isEnabled: Bool { blockedReason == nil }
}

/// Decides the one honest toolbar update, from already-loaded snapshot facts.
public enum BranchUpdatePlanner {
    public static func action(
        viewing: String,
        compare: String,
        compareTip: String,
        viewingBehind: Int,
        localCompareBehind: Int,
        checkedOutBranch: String?,
        hasLocalChanges: Bool,
        viewingOccupiedBy: String?,
        compareOccupiedBy: String?,
        viewingCanFastForward: Bool = true,
        localCompareCanFastForward: Bool = true
    ) -> BranchUpdateAction? {
        guard !viewing.isEmpty, !compare.isEmpty else { return nil }

        if viewingBehind > 0 {
            if viewing == compare {
                let occupied = occupiedBlock(
                    branch: viewing,
                    occupant: viewingOccupiedBy ?? compareOccupiedBy,
                    checkedOutBranch: checkedOutBranch
                )
                if !viewingCanFastForward {
                    var blocked = occupied
                    if blocked == nil, checkedOutBranch != viewing, hasLocalChanges {
                        blocked = "This folder has uncommitted changes, so BranchLens can’t check out \(viewing) to merge."
                    } else if blocked == nil, checkedOutBranch == viewing, hasLocalChanges {
                        blocked = "Uncommitted changes in this folder. Commit or stash first."
                    }
                    return BranchUpdateAction(
                        kind: .mergeIntoViewing,
                        title: "Merge \(compareTip)",
                        help: "\(viewing) and \(compareTip) have diverged. Merge to create a merge commit.",
                        blockedReason: blocked,
                        isPrimary: true
                    )
                }
                var blocked = occupied
                if blocked == nil, checkedOutBranch == viewing, hasLocalChanges {
                    blocked = "Uncommitted changes in this folder. Commit or stash first."
                }
                return BranchUpdateAction(
                    kind: .fastForwardViewing,
                    title: "Fast-forward \(viewing)",
                    help: "Fast-forward \(viewing) by \(viewingBehind) commit\(viewingBehind == 1 ? "" : "s") to \(compareTip).",
                    blockedReason: blocked,
                    isPrimary: true
                )
            }

            var blocked: String?
            if let other = viewingOccupiedBy, checkedOutBranch != viewing {
                blocked = "\(viewing) is checked out in \(other). Switch to that worktree to merge."
            } else if checkedOutBranch != viewing, hasLocalChanges {
                blocked = "This folder has uncommitted changes, so BranchLens can’t check out \(viewing) to merge."
            }
            return BranchUpdateAction(
                kind: .mergeIntoViewing,
                title: "Merge \(viewingBehind)",
                help: "Merge \(viewingBehind) commit\(viewingBehind == 1 ? "" : "s") from \(compareTip) into \(viewing).",
                blockedReason: blocked,
                isPrimary: true
            )
        }

        if localCompareBehind > 0, compareTip != compare {
            var blocked: String?
            if !localCompareCanFastForward {
                blocked = "Local \(compare) and \(compareTip) have diverged."
            } else if let other = compareOccupiedBy {
                blocked = "Local \(compare) is checked out in \(other)."
            } else if checkedOutBranch == compare, hasLocalChanges {
                blocked = "Uncommitted changes. Commit or stash before refreshing \(compare)."
            }
            return BranchUpdateAction(
                kind: .refreshLocalCompare,
                title: "Refresh \(compare) (−\(localCompareBehind))",
                help: "\(viewing) already includes \(compareTip). Local \(compare) is \(localCompareBehind) commit\(localCompareBehind == 1 ? "" : "s") behind. This does not change \(viewing).",
                blockedReason: blocked,
                isPrimary: false
            )
        }

        return nil
    }

    private static func occupiedBlock(
        branch: String,
        occupant: String?,
        checkedOutBranch: String?
    ) -> String? {
        guard let occupant, checkedOutBranch != branch else { return nil }
        return "\(branch) is checked out in \(occupant)."
    }
}

public enum BranchDeleteRules {
    public static let protectedReason = "Protected branch"

    public static func blockedReason(name: String, occupiedBy: String?) -> String? {
        if GitBranch.isProtectedName(name) {
            return protectedReason
        }
        if let occupiedBy, !occupiedBy.isEmpty {
            return "Checked out in \(occupiedBy)"
        }
        return nil
    }
}

public enum WorktreeActions {
    public static func isPrimary(_ worktree: GitWorktree, in all: [GitWorktree]) -> Bool {
        all.first?.path.standardizedFileURL == worktree.path.standardizedFileURL
    }

    public static func liveCount(_ worktrees: [GitWorktree]) -> Int {
        worktrees.filter(\.folderExists).count
    }

    public static func missingCount(_ worktrees: [GitWorktree]) -> Int {
        worktrees.filter { !$0.folderExists }.count
    }

    /// `nil` means the worktree can be removed or pruned.
    public static func blockedReason(
        _ worktree: GitWorktree,
        in all: [GitWorktree],
        currentPath: URL?,
        openPaths: Set<String>
    ) -> String? {
        if isPrimary(worktree, in: all) {
            return "The primary clone can’t be removed."
        }
        if let current = currentPath,
           worktree.path.standardizedFileURL == current.standardizedFileURL {
            return "This is the folder this tab is using."
        }
        if openPaths.contains(worktree.path.standardizedFileURL.path) {
            return "This folder is open in another tab."
        }
        return nil
    }
}

/// Compare should be a short base list, not the full branch phone book.
public enum CompareBranchOptions {
    public static let preferred = ["main", "master", "develop"]

    public static func bases(from branches: [String], current: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ name: String) {
            guard branches.contains(name), seen.insert(name).inserted else { return }
            result.append(name)
        }
        add(current)
        preferred.forEach(add)
        for name in branches where name.hasPrefix("release/") || name.hasPrefix("release-") {
            add(name)
        }
        return result.isEmpty ? branches : result
    }
}
