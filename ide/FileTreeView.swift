import SwiftUI
import AppKit

// Lazy folder/file tree, rooted at the project folder. Each row shows the
// system file icon plus the file name; tapping a file calls `onSelect`.
struct FileTreeView: View {

    let root: FileNode
    let version: Int   // bumped externally to force rebuild after disk changes
    let onSelect: (URL) -> Void

    var body: some View {
        List {
            if let kids = root.children {
                OutlineGroup(kids, id: \.id, children: \.children) { node in
                    FileRow(node: node)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !node.isDirectory {
                                onSelect(node.url)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .id(version)   // force the OutlineGroup to rebuild when version changes
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.icon(for: node.url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private static func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
