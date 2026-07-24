import Foundation

enum PaneFactory {
    static func editorPane(for url: URL, line: Int? = nil, searchTerm: String? = nil) -> PaneModel {
        let pane = PaneModel()
        pane.createEditorViewController(for: url)

        if let searchTerm, !searchTerm.isEmpty {
            pane.editorViewController?.highlightOccurrences(of: searchTerm)
        }

        if let line, let editorViewController = pane.editorViewController {
            editorViewController.navigateToLine(line)
        }

        return pane
    }

    static func diffPane(for filePath: String, kind: GitDiffKind = .uncommitted) -> PaneModel {
        let pane = PaneModel()
        pane.createDiffViewController(for: filePath, kind: kind)
        return pane
    }

    static func uncommittedChangesPane(
        repositoryPath: String,
        focusedFilePath: String? = nil,
        onOpenFile: ((String) -> Void)? = nil
    ) -> PaneModel {
        let pane = PaneModel()
        pane.createUncommittedChangesViewController(
            repositoryPath: repositoryPath,
            focusedFilePath: focusedFilePath,
            onOpenFile: onOpenFile
        )
        return pane
    }
}
