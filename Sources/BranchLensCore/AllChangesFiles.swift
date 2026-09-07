import Foundation

/// File list for the All changes card.
public enum AllChangesFiles {
    /// Viewing…Compare files, plus this folder’s staged/unstaged paths that are not already on Viewing.
    ///
    /// Used when Viewing is not HEAD. Do not run `changedFilesToWorktree(from: mergeBase)` in that
    /// case — that diffs this folder’s checkout and pulls in the other branch’s commits.
    public static func viewingPlusLocal(
        branchFiles: [ChangedFile],
        workingTreeFiles: [WorkingTreeFile]
    ) -> [ChangedFile] {
        var byPath: [String: ChangedFile] = [:]
        byPath.reserveCapacity(branchFiles.count + workingTreeFiles.count)
        for file in branchFiles {
            byPath[file.path] = file
        }
        for local in workingTreeFiles where byPath[local.path] == nil {
            byPath[local.path] = local.asChangedFile
        }
        return byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
