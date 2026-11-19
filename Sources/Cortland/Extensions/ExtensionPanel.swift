import AppKit

// MARK: - Panel output

/// What an extension's `command panel` prints: one JSON object, for example
///
///     {
///       "message": "optional line shown above the sections",
///       "sections": [
///         { "title": "Widgets", "empty": "No widgets",
///           "rows": [ { "id": "widget/alpha", "title": "alpha",
///                       "detail": "default:v1 · us-west-2 · 10h left",
///                       "icon": "bolt" } ] }
///       ]
///     }
///
/// Top-level `actions` and row `actions` are optional lists of
/// `{ "id", "title", "confirm"?, "icon"?, "menu"?, "choose"? }`; see
/// `ExtensionPanelAction` and `ExtensionPanelMenuItem`.
///
/// Unknown keys are ignored at every level, so output written for a later
/// API still decodes.
nonisolated struct ExtensionPanelContent: Equatable, Sendable, Decodable {
    nonisolated struct Section: Equatable, Sendable, Decodable {
        let title: String
        let empty: String?
        let rows: [Row]

        private enum CodingKeys: String, CodingKey { case title, empty, rows }

        init(title: String, empty: String? = nil, rows: [Row] = []) {
            self.title = title
            self.empty = empty
            self.rows = rows
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            empty = try container.decodeIfPresent(String.self, forKey: .empty)
            rows = try container.decodeIfPresent([Row].self, forKey: .rows) ?? []
        }
    }

    nonisolated struct Row: Equatable, Sendable, Decodable {
        let id: String
        let title: String
        let detail: String?
        let icon: String?
        let actions: [ExtensionPanelAction]

        private enum CodingKeys: String, CodingKey { case id, title, detail, icon, actions }

        init(id: String, title: String, detail: String? = nil, icon: String? = nil, actions: [ExtensionPanelAction] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.icon = icon
            self.actions = actions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            actions = try container.decodeIfPresent([ExtensionPanelAction].self, forKey: .actions) ?? []
        }
    }

    let message: String?
    let sections: [Section]
    /// Actions on the panel as a whole.
    let actions: [ExtensionPanelAction]

    private enum CodingKeys: String, CodingKey { case message, sections, actions }

    init(message: String? = nil, sections: [Section] = [], actions: [ExtensionPanelAction] = []) {
        self.message = message
        self.sections = sections
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
        actions = try container.decodeIfPresent([ExtensionPanelAction].self, forKey: .actions) ?? []
    }

    /// Decodes and validates panel output. The error's description is the
    /// short reason the panel shows.
    static func decode(_ data: Data) throws(ExtensionPanelError) -> ExtensionPanelContent {
        let content: ExtensionPanelContent
        do {
            content = try JSONDecoder().decode(ExtensionPanelContent.self, from: data)
        } catch let error as ExtensionPanelError {
            throw error
        } catch let error as DecodingError {
            throw .invalidOutput(describe(error))
        } catch {
            throw .invalidOutput(error.localizedDescription)
        }

        try ExtensionPanelAction.validate(content.actions, in: "the panel")
        var seen = Set<String>()
        for section in content.sections {
            for row in section.rows {
                guard !row.id.isEmpty else { throw .invalidOutput("a row in \"\(section.title)\" has an empty \"id\"") }
                guard seen.insert(row.id).inserted else { throw .invalidOutput("duplicate row id \"\(row.id)\"") }
                try ExtensionPanelAction.validate(row.actions, in: "row \"\(row.id)\"")
            }
        }
        return content
    }

    fileprivate static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let parts = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return parts.isEmpty ? "top level" : parts.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "output is not valid JSON" : "invalid value at \(path(context.codingPath))"
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\" at \(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "wrong type at \(path(context.codingPath)), expected \(type)"
        case .valueNotFound(let type, let context):
            return "null at \(path(context.codingPath)), expected \(type)"
        @unknown default:
            return "output could not be decoded"
        }
    }
}

/// Something the user can do to a row or to the whole panel. Running it runs
/// `<command> action <id> [<row id>] [<path>]`. With `confirm`, the user is
/// asked first. With `menu`, choosing it in the panel opens that menu instead
/// of running. With `choose`, the user picks a folder first and its path is
/// the last argument.
nonisolated struct ExtensionPanelAction: Equatable, Sendable, Decodable {
    let id: String
    let title: String
    let confirm: String?
    /// An SF Symbol name. A panel action with a real symbol gets its own
    /// button in the panel's top bar; without one it goes in the Actions menu.
    /// A row action with a real symbol gets a button on its row, shown while
    /// the pointer is over the row.
    let icon: String?
    /// Items shown when the action is chosen in the panel, in place of
    /// running it. Non-empty when present. The command palette ignores it
    /// and runs the action itself.
    let menu: [ExtensionPanelMenuItem]?
    /// What the user picks before the action runs, or nil for nothing.
    let choose: Choice?

    /// Something the user picks in a system panel before an action runs.
    enum Choice: String, Equatable, Sendable {
        case folder
    }

    private enum CodingKeys: String, CodingKey { case id, title, confirm, icon, menu, choose }

    init(
        id: String,
        title: String,
        confirm: String? = nil,
        icon: String? = nil,
        menu: [ExtensionPanelMenuItem]? = nil,
        choose: Choice? = nil
    ) {
        self.id = id
        self.title = title
        self.confirm = confirm
        self.icon = icon
        self.menu = menu
        self.choose = choose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        confirm = try container.decodeIfPresent(String.self, forKey: .confirm)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        menu = try container.decodeIfPresent([ExtensionPanelMenuItem].self, forKey: .menu)
        if let name = try container.decodeIfPresent(String.self, forKey: .choose) {
            guard let choice = Choice(rawValue: name) else {
                throw ExtensionPanelError.invalidOutput("action \"\(id)\" has \"choose\": \"\(name)\"; the only value is \"folder\"")
            }
            choose = choice
        } else {
            choose = nil
        }
    }

    /// Non-empty ids and titles, ids unique within one list, a valid `menu`
    /// when present, and never both `menu` and `choose`.
    fileprivate static func validate(_ actions: [ExtensionPanelAction], in owner: String) throws(ExtensionPanelError) {
        var seen = Set<String>()
        for action in actions {
            guard !action.id.isEmpty else { throw .invalidOutput("an action in \(owner) has an empty \"id\"") }
            guard !action.title.isEmpty else { throw .invalidOutput("action \"\(action.id)\" in \(owner) has an empty \"title\"") }
            guard seen.insert(action.id).inserted else { throw .invalidOutput("duplicate action id \"\(action.id)\" in \(owner)") }
            if let menu = action.menu {
                guard action.choose == nil else {
                    throw .invalidOutput("action \"\(action.id)\" in \(owner) has both \"menu\" and \"choose\"")
                }
                try ExtensionPanelMenuItem.validate(menu, depth: 1, in: "action \"\(action.id)\" in \(owner)")
            }
        }
    }
}

/// One entry in an action's `menu`. A leaf runs `<command> action <id>`,
/// with `row` appended when it is non-empty, through the same runner as any
/// other action. An item with its own `menu` opens a submenu and never runs.
/// Ids need not be unique: items may share an id and differ by `row`.
nonisolated struct ExtensionPanelMenuItem: Equatable, Sendable, Decodable {
    let id: String
    let title: String
    let confirm: String?
    /// The row id to run the action with. Need not be a row in the panel.
    let row: String?
    let menu: [ExtensionPanelMenuItem]?

    /// Menus in total, the top one included.
    static let maxDepth = 3

    private enum CodingKeys: String, CodingKey { case id, title, confirm, row, menu }

    init(id: String, title: String, confirm: String? = nil, row: String? = nil, menu: [ExtensionPanelMenuItem]? = nil) {
        self.id = id
        self.title = title
        self.confirm = confirm
        self.row = row
        self.menu = menu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        confirm = try container.decodeIfPresent(String.self, forKey: .confirm)
        row = try container.decodeIfPresent(String.self, forKey: .row)
        menu = try container.decodeIfPresent([ExtensionPanelMenuItem].self, forKey: .menu)
    }

    /// The row id a leaf runs with: `row` when non-empty, else nil (a panel
    /// action).
    var rowID: String? {
        guard let row, !row.isEmpty else { return nil }
        return row
    }

    /// The action the shared runner runs for this leaf.
    var runnableAction: ExtensionPanelAction {
        ExtensionPanelAction(id: id, title: title, confirm: confirm)
    }

    /// `items` is the menu at `depth` (1 for an action's own menu): not
    /// empty, no deeper than `maxDepth`, each item with a non-empty id and
    /// title, and no `row` or `confirm` on an item that has a `menu`.
    fileprivate static func validate(_ items: [ExtensionPanelMenuItem], depth: Int, in owner: String) throws(ExtensionPanelError) {
        guard !items.isEmpty else { throw .invalidOutput("\(owner) has an empty \"menu\"") }
        guard depth <= maxDepth else { throw .invalidOutput("\(owner) nests menus more than \(maxDepth) deep") }
        for item in items {
            guard !item.id.isEmpty else { throw .invalidOutput("a menu item in \(owner) has an empty \"id\"") }
            guard !item.title.isEmpty else { throw .invalidOutput("menu item \"\(item.id)\" in \(owner) has an empty \"title\"") }
            guard let submenu = item.menu else { continue }
            guard item.row == nil else { throw .invalidOutput("menu item \"\(item.title)\" in \(owner) has both \"menu\" and \"row\"") }
            guard item.confirm == nil else { throw .invalidOutput("menu item \"\(item.title)\" in \(owner) has both \"menu\" and \"confirm\"") }
            try validate(submenu, depth: depth + 1, in: owner)
        }
    }
}

/// What `<command> action ...` prints: one JSON object saying what Cortland
/// does next, for example
///
///     { "open_tab": { "command": ["ssh", "example-host"] } }
///     { "open_url": "https://warm-orbit.example.com/" }
///     { "copy": "https://warm-orbit.example.com/" }
///
/// Any combination of the keys may appear; each present effect is carried
/// out. `{}` means nothing more to do. Unknown keys are ignored.
nonisolated struct ExtensionActionResult: Equatable, Sendable, Decodable {
    /// An argv to run in a new terminal tab, or nil.
    let openTab: [String]?
    /// An http or https URL to open in the default browser, or nil.
    let openURL: URL?
    /// Text to put on the general pasteboard, or nil.
    let copy: String?

    private enum CodingKeys: String, CodingKey {
        case openTab = "open_tab"
        case openURL = "open_url"
        case copy
    }
    private enum OpenTabKeys: String, CodingKey { case command }

    init(openTab: [String]? = nil, openURL: URL? = nil, copy: String? = nil) {
        self.openTab = openTab
        self.openURL = openURL
        self.copy = copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.openTab) {
            let tab = try container.nestedContainer(keyedBy: OpenTabKeys.self, forKey: .openTab)
            openTab = try tab.decode([String].self, forKey: .command)
        } else {
            openTab = nil
        }
        openURL = try container.decodeIfPresent(String.self, forKey: .openURL).map(Self.webURL)
        copy = try container.decodeIfPresent(String.self, forKey: .copy)
    }

    /// `text` as a URL with scheme http or https and a non-empty host.
    /// Control characters are rejected before parsing, since `URL(string:)`
    /// may percent-encode them instead of failing.
    private static func webURL(_ text: String) throws(ExtensionPanelError) -> URL {
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw .invalidOutput("\"open_url\" contains a control character")
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw .invalidOutput("\"open_url\" must be an http or https URL")
        }
        guard let host = url.host, !host.isEmpty else {
            throw .invalidOutput("\"open_url\" has no host")
        }
        return url
    }

    /// Decodes and validates action output. The command must be a non-empty
    /// argv of non-empty strings with no control characters, since it is
    /// typed into a shell. `open_url` must be an http or https URL with a
    /// host, and `copy` must not be empty. Any violation makes the whole
    /// result invalid, so none of its effects are carried out.
    static func decode(_ data: Data) throws(ExtensionPanelError) -> ExtensionActionResult {
        let result: ExtensionActionResult
        do {
            result = try JSONDecoder().decode(ExtensionActionResult.self, from: data)
        } catch let error as ExtensionPanelError {
            throw error
        } catch let error as DecodingError {
            throw .invalidOutput(ExtensionPanelContent.describe(error))
        } catch {
            throw .invalidOutput(error.localizedDescription)
        }
        if let command = result.openTab {
            guard !command.isEmpty else { throw .invalidOutput("\"open_tab.command\" is empty") }
            for (index, argument) in command.enumerated() {
                guard !argument.isEmpty else { throw .invalidOutput("open_tab.command[\(index)] is empty") }
                let hasControl = argument.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
                guard !hasControl else { throw .invalidOutput("open_tab.command[\(index)] contains a control character") }
            }
        }
        if let copy = result.copy, copy.isEmpty {
            throw .invalidOutput("\"copy\" is empty")
        }
        return result
    }
}

/// POSIX shell quoting for a command line typed into a terminal.
nonisolated enum ShellQuoting {
    /// Each element quoted as needed, joined by spaces.
    static func commandLine(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    /// Left bare when made only of ASCII letters, digits, and `@%+=:,./_-`;
    /// otherwise wrapped in single quotes, with `'` written as `'\''`.
    static func quote(_ argument: String) -> String {
        let isSafe = !argument.isEmpty && argument.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": return true
            default: return "@%+=:,./_-".unicodeScalars.contains(scalar)
            }
        }
        if isSafe { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

nonisolated enum ExtensionPanelError: Error, Equatable, Sendable, LocalizedError {
    /// The command could not be started.
    case launchFailed(String)
    /// Non-zero exit; carries the first non-empty stderr line (may be empty).
    case exited(status: Int32, stderr: String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "could not run the command: \(detail)"
        case .exited(let status, let stderr):
            return stderr.isEmpty ? "exited with status \(status)" : stderr
        case .invalidOutput(let detail):
            return detail
        }
    }
}

/// What a panel shows: nothing yet, content, or an error from the last run.
nonisolated enum ExtensionPanelState: Equatable, Sendable {
    case loading
    case content(ExtensionPanelContent)
    case failed(String)
}

// MARK: - Running the command

/// Runs `<command> panel` in the extension's folder and decodes its output.
/// Blocking; call it off the main thread.
nonisolated struct ExtensionPanelCommand: Sendable {
    let executableURL: URL
    let folder: URL
    let runner: ProcessRunning

    init(executableURL: URL, folder: URL, runner: ProcessRunning = ProcessRunner.shared) {
        self.executableURL = executableURL
        self.folder = folder
        self.runner = runner
    }

    init(extension installed: InstalledExtension, runner: ProcessRunning = ProcessRunner.shared) {
        self.init(executableURL: installed.manifest.commandURL, folder: installed.folder, runner: runner)
    }

    /// `searchPath` becomes the child's PATH. The default asks the user's shell
    /// once, because an app launched from Finder has a bare PATH.
    func run(searchPath: String = DocumentFormatter.shellSearchPath) -> Result<ExtensionPanelContent, ExtensionPanelError> {
        execute(arguments: ["panel"], searchPath: searchPath).flatMap { stdout in
            Result { () throws(ExtensionPanelError) in try ExtensionPanelContent.decode(Data(stdout.utf8)) }
        }
    }

    /// Runs `<command> action <actionID> [<rowID>] [<path>]` and decodes its
    /// result. A nil `rowID` is a panel action. `path` is what the user chose
    /// for an action with `choose`.
    func runAction(
        _ actionID: String,
        rowID: String?,
        path: String? = nil,
        searchPath: String = DocumentFormatter.shellSearchPath
    ) -> Result<ExtensionActionResult, ExtensionPanelError> {
        var arguments = ["action", actionID]
        if let rowID { arguments.append(rowID) }
        if let path { arguments.append(path) }
        return execute(arguments: arguments, searchPath: searchPath).flatMap { stdout in
            Result { () throws(ExtensionPanelError) in try ExtensionActionResult.decode(Data(stdout.utf8)) }
        }
    }

    /// Runs the command with `arguments`; stdout on a zero exit.
    private func execute(arguments: [String], searchPath: String) -> Result<String, ExtensionPanelError> {
        let result: ProcessResult
        do {
            result = try runner.run(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: folder,
                environment: ["PATH": searchPath]
            )
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        guard result.succeeded else {
            return .failure(.exited(status: result.terminationStatus, stderr: Self.firstLine(of: result.stderr)))
        }
        return .success(result.stdout)
    }

    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

// MARK: - Refresh

/// Drives one panel's refreshes: runs the command when asked, never two at
/// once, and reports a new state only when it differs from the shown one.
final class ExtensionPanelRefresher {
    /// Starts one load and calls the completion on the main actor with its
    /// result. Injected so tests can hold a load open.
    typealias Loader = (@escaping @MainActor (Result<ExtensionPanelContent, ExtensionPanelError>) -> Void) -> Void

    private(set) var state: ExtensionPanelState = .loading
    private(set) var isLoading = false
    /// Set by `refreshAfterCurrentLoad` while a load is in flight.
    private var refreshQueued = false
    /// Called after `state` changes. Not called when a refresh returns what is
    /// already shown, so the view is not reloaded.
    var onStateChange: ((ExtensionPanelState) -> Void)?

    let refreshInterval: TimeInterval
    private let load: Loader
    /// nonisolated(unsafe) only so deinit can invalidate it; every other
    /// touch is on the main actor, where the timer was scheduled.
    nonisolated(unsafe) private var timer: Timer?

    var isActive: Bool { timer != nil }

    init(refreshInterval: TimeInterval, load: @escaping Loader) {
        self.refreshInterval = refreshInterval
        self.load = load
    }

    /// The standard loader: runs `command` on a background queue.
    convenience init(command: ExtensionPanelCommand, refreshInterval: TimeInterval) {
        self.init(refreshInterval: refreshInterval) { completion in
            DispatchQueue.global(qos: .utility).async {
                let result = command.run()
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Starts a load unless one is already in flight.
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        load { [weak self] result in
            self?.finish(result)
        }
    }

    /// Like `refresh`, but when a load is already in flight, starts another
    /// once it finishes, so the panel shows output produced after this call.
    func refreshAfterCurrentLoad() {
        if isLoading {
            refreshQueued = true
        } else {
            refresh()
        }
    }

    private func finish(_ result: Result<ExtensionPanelContent, ExtensionPanelError>) {
        isLoading = false
        defer {
            if refreshQueued {
                refreshQueued = false
                refresh()
            }
        }
        let newState: ExtensionPanelState
        switch result {
        case .success(let content): newState = .content(content)
        case .failure(let error): newState = .failed(error.localizedDescription)
        }
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Active while the panel is the visible sidebar panel: refreshes now, then
    /// on a timer. Inactive stops the timer; a run in flight still finishes.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            refresh()
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Actions

/// Runs one extension's actions: at most one at a time, asking first when an
/// action has `confirm`, then carrying out the result's effects (or showing
/// the failure) and calling `onFinish`. The sidebar panel and the command
/// palette share one runner per extension, so both go through this one path
/// and the one-at-a-time rule covers both.
final class ExtensionPanelActionRunner {
    /// Starts one action run (`rowID` nil for a panel action, `path` nil
    /// unless the action has `choose`) and calls the completion on the main
    /// actor. Injected so tests can hold a run open.
    typealias Performer = (
        _ actionID: String,
        _ rowID: String?,
        _ path: String?,
        _ completion: @escaping @MainActor (Result<ExtensionActionResult, ExtensionPanelError>) -> Void
    ) -> Void

    private(set) var isRunning = false
    /// A shell command line to run in a new terminal tab.
    var onOpenTab: ((String) -> Void)?
    /// An http or https URL to open in the default browser.
    var onOpenURL: ((URL) -> Void)?
    /// Text to put on the general pasteboard as plain text.
    var onCopy: ((String) -> Void)?
    /// Asks the user to confirm an action that has `confirm`; true runs it.
    /// Injected so tests do not show an alert.
    var confirmAction: @MainActor (ExtensionPanelAction) -> Bool = ExtensionPanelActionRunner.confirmWithAlert
    /// Asks the user for the folder an action with `choose` needs, and calls
    /// the completion with its path, or nil when they cancel. Injected so
    /// tests do not show a panel.
    var chooseFolder: @MainActor (ExtensionPanelAction, @escaping @MainActor (String?) -> Void) -> Void =
        ExtensionPanelActionRunner.chooseFolderWithOpenPanel
    /// Shows a failed action's title and reason. Injected for tests.
    var showFailure: @MainActor (_ title: String, _ reason: String) -> Void = ExtensionPanelActionRunner.showFailureAlert
    /// Called after every run, success or failure.
    var onFinish: (() -> Void)?

    private let perform: Performer

    init(perform: @escaping Performer) {
        self.perform = perform
    }

    /// The standard performer: runs `command` on a background queue.
    convenience init(command: ExtensionPanelCommand) {
        self.init { actionID, rowID, path, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = command.runAction(actionID, rowID: rowID, path: path)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Runs `action`, for the row with `rowID` or (nil) for the panel: has
    /// the user pick a folder first when it has `choose`, asks when it has
    /// `confirm`, and does nothing while another runs. Cancelling either
    /// runs nothing.
    func perform(_ action: ExtensionPanelAction, rowID: String?) {
        guard !isRunning else { return }
        guard action.choose != nil else {
            if action.confirm != nil, !confirmAction(action) { return }
            run(action, rowID: rowID)
            return
        }
        chooseFolder(action) { [weak self] path in
            guard let self, let path else { return }
            if action.confirm != nil, !self.confirmAction(action) { return }
            self.run(action, rowID: rowID, path: path)
        }
    }

    /// Starts `action` without asking. Returns false, running nothing, while
    /// another runs.
    @discardableResult
    func run(_ action: ExtensionPanelAction, rowID: String?, path: String? = nil) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        perform(action.id, rowID, path) { [weak self] result in
            self?.finish(action, result)
        }
        return true
    }

    private func finish(_ action: ExtensionPanelAction, _ result: Result<ExtensionActionResult, ExtensionPanelError>) {
        isRunning = false
        switch result {
        case .success(let outcome):
            if let command = outcome.openTab {
                onOpenTab?(ShellQuoting.commandLine(command))
            }
            if let url = outcome.openURL {
                onOpenURL?(url)
            }
            if let text = outcome.copy {
                onCopy?(text)
            }
        case .failure(let error):
            showFailure(action.title, error.localizedDescription)
        }
        onFinish?()
    }

    private static func confirmWithAlert(_ action: ExtensionPanelAction) -> Bool {
        let alert = NSAlert()
        alert.messageText = action.confirm ?? action.title
        alert.addButton(withTitle: action.title)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The real `chooseFolder`: an open panel that picks one folder, as a
    /// sheet on the main window when there is one. The action's title, less
    /// a trailing ellipsis, is the panel's message.
    private static func chooseFolderWithOpenPanel(
        _ action: ExtensionPanelAction,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = action.title.trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
        panel.prompt = "Choose"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                completion(response == .OK ? panel.url?.path : nil)
            }
        }
        if let window = NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// The failure alert: `title` as the message, `reason` below it.
    static func showFailureAlert(title: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// The real `onOpenURL`: the default browser.
    static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The real `onCopy`: plain text on the general pasteboard.
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Sidebar entries

nonisolated extension InstalledExtension {
    /// The extensions that get a sidebar panel: enabled, with a `[panel]`
    /// table, ordered by name.
    static func panelExtensions(_ extensions: [InstalledExtension]) -> [InstalledExtension] {
        extensions
            .filter { $0.isEnabled && $0.manifest.panel != nil }
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }
}
