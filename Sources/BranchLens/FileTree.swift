import BranchLensCore
import Foundation

enum FilesLayoutMode: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case folders = "Folders"

    var id: String { rawValue }
}

struct FileTreeNode: Identifiable, Hashable, Equatable {
    let id: String
    let name: String
    let file: ChangedFile?
    var children: [FileTreeNode]

    var isFolder: Bool { file == nil }

    static func build(from files: [ChangedFile]) -> [FileTreeNode] {
        final class Dir {
            var children: [String: Dir] = [:]
            var files: [ChangedFile] = []
        }

        let root = Dir()
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            guard let last = parts.last else { continue }
            var node = root
            if parts.count > 1 {
                for folder in parts.dropLast() {
                    if node.children[folder] == nil {
                        node.children[folder] = Dir()
                    }
                    node = node.children[folder]!
                }
            }
            _ = last
            node.files.append(file)
        }

        func convert(_ dir: Dir, path: String) -> [FileTreeNode] {
            let folderNodes: [FileTreeNode] = dir.children.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
                let childPath = path.isEmpty ? name : "\(path)/\(name)"
                return FileTreeNode(
                    id: "folder:\(childPath)",
                    name: name,
                    file: nil,
                    children: convert(dir.children[name]!, path: childPath)
                )
            }
            let fileNodes: [FileTreeNode] = dir.files
                .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
                .map { file in
                    FileTreeNode(
                        id: "file:\(file.path)",
                        name: (file.path as NSString).lastPathComponent,
                        file: file,
                        children: []
                    )
                }
            return folderNodes + fileNodes
        }

        return convert(root, path: "")
    }
}

enum TextUtilities {
    static func lineCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func matchCount(in text: String, query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}
