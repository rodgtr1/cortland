import Foundation

enum PaneFactory {
    static func editorPane(
        for url: URL,
        line: Int? = nil,
        searchTerm: String? = nil,
        agentsForRepository: ((String) -> [ChangesComments.Agent])? = nil,
        sendToAgent: ((UUID, String) -> Bool)? = nil
    ) -> PaneModel {
        let pane = PaneModel()
        pane.createEditorViewController(for: url)
        pane.editorViewController?.agentsForRepository = agentsForRepository
        pane.editorViewController?.sendToAgent = sendToAgent

        if let searchTerm, !searchTerm.isEmpty {
            pane.editorViewController?.highlightOccurrences(of: searchTerm)
        }

        if let line, let editorViewController = pane.editorViewController {
            editorViewController.navigateToLine(line)
        }

        return pane
    }

    static func uncommittedChangesPane(
        repositoryPath: String,
        source: ChangesSource = .uncommitted,
        focusedFilePath: String? = nil,
        onOpenFile: ((String) -> Void)? = nil,
        agentsForRepository: ((String) -> [ChangesComments.Agent])? = nil,
        sendToAgent: ((UUID, String) -> Bool)? = nil,
        agentStateForPane: ((UUID) -> AgentState?)? = nil
    ) -> PaneModel {
        let pane = PaneModel()
        pane.createUncommittedChangesViewController(
            repositoryPath: repositoryPath,
            source: source,
            focusedFilePath: focusedFilePath,
            onOpenFile: onOpenFile,
            agentsForRepository: agentsForRepository,
            sendToAgent: sendToAgent,
            agentStateForPane: agentStateForPane
        )
        return pane
    }
}
