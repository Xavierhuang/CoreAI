import Foundation
import AppKit

// A lazily-populated node in the file tree. Directories load their children
// on first access (dotfiles excluded), sorted folders-first then by name.
// Reference type so SwiftUI's OutlineGroup can keep stable identity per node
// as the tree expands/collapses.
final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let name: String

    private var cachedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        self.name = url.lastPathComponent
    }

    var id: URL { url }

    /// nil for files (so OutlineGroup treats them as leaves);
    /// loaded-and-cached array for directories.
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let cached = cachedChildren { return cached }
        cachedChildren = Self.readChildren(of: url)
        return cachedChildren
    }

    func invalidateChildren() {
        cachedChildren = nil
    }

    private static func readChildren(of url: URL) -> [FileNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let nodes = contents.map { child -> FileNode in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(url: child, isDirectory: isDir)
        }
        // Folders first, then case-insensitive name order.
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
