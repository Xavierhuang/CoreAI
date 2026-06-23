import Foundation
import AppKit
import SwiftUI

// Per-window state. One instance per editor window.
// @Observable for SwiftUI bindings; runs on the main actor since it touches
// AppKit (NSOpenPanel/NSSavePanel) and view state.
@MainActor
@Observable
final class EditorViewModel {

    var rootFolderURL: URL?
    var currentFileURL: URL?
    var text: String = ""
    var isDirty: Bool = false

    // Tree state. Recreated when rootFolderURL changes; replaced (with a new
    // FileNode instance) when the disk tree needs to be re-read after Claude
    // edits files.
    var rootNode: FileNode?
    var treeVersion: Int = 0   // bump to force OutlineGroup to refresh

    /// Window title. File name wins if a file is open; otherwise the folder
    /// name; otherwise "Untitled".
    var windowTitle: String {
        if let f = currentFileURL { return f.lastPathComponent }
        if let r = rootFolderURL { return r.lastPathComponent }
        return "Untitled"
    }

    // MARK: - File operations

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.urls.first {
            loadFile(at: url)
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            setRootFolder(url)
        }
    }

    func setRootFolder(_ url: URL) {
        rootFolderURL = url
        rootNode = FileNode(url: url, isDirectory: true)
        treeVersion &+= 1
    }

    func loadFile(at url: URL) {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            text = contents
            currentFileURL = url
            isDirty = false
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveFile() {
        if let path = currentFileURL {
            write(to: path)
            return
        }
        let panel = NSSavePanel()
        if panel.runModal() == .OK, let url = panel.url {
            currentFileURL = url
            write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Claude callbacks

    /// Called after Claude finishes a turn — the CLI may have edited files on
    /// disk, so reload the tree and the currently-open file.
    func didModifyFilesViaClaude() {
        if let url = rootFolderURL {
            rootNode = FileNode(url: url, isDirectory: true)
            treeVersion &+= 1
        }
        if let url = currentFileURL,
           let reloaded = try? String(contentsOf: url, encoding: .utf8) {
            text = reloaded
            isDirty = false
        }
    }
}
