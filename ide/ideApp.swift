import SwiftUI

@main
struct ideApp: App {

    var body: some Scene {
        WindowGroup {
            EditorWindow()
        }
        .commands {
            // Replace the default "New" group with our own New Window plus
            // Open / Open Folder, then add Save in a sibling group so the
            // standard Cmd-key shortcuts feel familiar.
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
                Divider()
                OpenFileButton()
                OpenFolderButton()
                Divider()
                SaveButton()
            }
        }
    }
}

// MARK: - Menu items

// Each command needs to know which window is focused. SwiftUI's
// @FocusedValue gives us the per-scene view model registered by EditorWindow.

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Window") { openWindow(id: "main") }
            .keyboardShortcut("n", modifiers: [.command])
    }
}

private struct OpenFileButton: View {
    @FocusedValue(\.editorViewModel) private var vm
    var body: some View {
        Button("Open…") { vm?.openFile() }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(vm == nil)
    }
}

private struct OpenFolderButton: View {
    @FocusedValue(\.editorViewModel) private var vm
    var body: some View {
        Button("Open Folder…") { vm?.openFolder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(vm == nil)
    }
}

private struct SaveButton: View {
    @FocusedValue(\.editorViewModel) private var vm
    var body: some View {
        Button("Save") { vm?.saveFile() }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(vm == nil)
    }
}
