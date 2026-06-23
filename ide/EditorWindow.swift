import SwiftUI
import AppKit

// Root view of each editor window. Three-pane HSplitView: file tree on the
// left, code editor in the middle, Claude chat on the right.
struct EditorWindow: View {

    @State private var viewModel = EditorViewModel()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 150, idealWidth: 220)
            CodeEditorView(text: $viewModel.text)
                .frame(minWidth: 200, idealWidth: 480)
                .onChange(of: viewModel.text) {
                    viewModel.isDirty = true
                }
            AIChatView(
                rootURL: viewModel.rootFolderURL,
                onFilesModified: { viewModel.didModifyFilesViaClaude() }
            )
            .frame(minWidth: 220, idealWidth: 330)
        }
        .navigationTitle(viewModel.windowTitle)
        // Surface this window's view model so the File menu commands can
        // dispatch into the focused window.
        .focusedSceneValue(\.editorViewModel, viewModel)
    }

    @ViewBuilder
    private var sidebar: some View {
        if let root = viewModel.rootNode {
            FileTreeView(
                root: root,
                version: viewModel.treeVersion,
                onSelect: { viewModel.loadFile(at: $0) }
            )
        } else {
            VStack(spacing: 8) {
                Text("No folder open")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Open Folder…") { viewModel.openFolder() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Focused-value plumbing for menu commands

private struct EditorViewModelFocusKey: FocusedValueKey {
    typealias Value = EditorViewModel
}

extension FocusedValues {
    var editorViewModel: EditorViewModel? {
        get { self[EditorViewModelFocusKey.self] }
        set { self[EditorViewModelFocusKey.self] = newValue }
    }
}
