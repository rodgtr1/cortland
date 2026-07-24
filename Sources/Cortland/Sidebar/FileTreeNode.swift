import Foundation
import Cocoa
import UniformTypeIdentifiers

// Deliberately non-isolated so directory scans can run off the main thread (see
// FileTreeViewController). The threading contract that keeps this @unchecked
// Sendable sound — without blanket locking — is:
//
//   • `children` / `isLoaded` are part of the live tree that AppKit's data
//     source walks on the main thread, so they are only ever MUTATED on the
//     main thread (`commitChildren`) — or on a node that is still DETACHED from
//     the live tree (`loadSubtree`), where no other thread can observe it yet.
//   • `scanChildren` performs the heavy directory I/O and returns a fresh array
//     WITHOUT touching `self`, so it is safe to call from any queue.
//
// Under the target's default MainActor isolation, leaving this isolated would
// make the background scans trap when called off-main, hence `nonisolated`.
nonisolated final class FileTreeNode: @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool

    var children: [FileTreeNode] = []
    var isExpanded: Bool = false
    var isLoaded: Bool = false

    weak var parent: FileTreeNode?

    var icon: NSImage? {
        if isDirectory {
            // SF Symbols has no "folder.open"; a nonexistent name returns nil
            // and the row renders glyph-less, so expanded folders stop looking
            // like folders. Use the filled variant for the open state instead.
            return isExpanded ?
                NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Open folder") :
                NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        } else {
            if #available(macOS 12.0, *) {
                let contentType = UTType(filenameExtension: url.pathExtension) ?? .data
                return NSWorkspace.shared.icon(for: contentType)
            } else {
                return NSWorkspace.shared.icon(forFileType: url.pathExtension)
            }
        }
    }

    var isGitIgnored: Bool = false

    init(url: URL, parent: FileTreeNode? = nil, isDirectory: Bool? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.parent = parent

        if let isDirectory = isDirectory {
            self.isDirectory = isDirectory
        } else {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            self.isDirectory = exists && isDir.boolValue
        }

        // Check if hidden (starts with .)
        self.isHidden = name.hasPrefix(".")

        // Directories load their children lazily on expansion; files have none.
        self.isLoaded = !self.isDirectory
    }

    /// Quick synchronous check if directory has any children (for showing disclosure triangle)
    func hasChildren(showHidden: Bool = false) -> Bool {
        guard isDirectory else { return false }

        if isLoaded {
            return !children.isEmpty
        }

        // Avoid synchronous directory scans on the main thread while AppKit asks
        // whether rows are expandable. The actual children load on expansion.
        return true
    }

    /// Scans this directory and returns freshly built child nodes. Does NOT
    /// mutate `self`, so it is safe to call from any queue (the heavy I/O is
    /// meant to run off the main thread). Publish the result onto a live node
    /// with `commitChildren(_:)` on the main thread, or build a detached subtree
    /// with `loadSubtree(...)`.
    func scanChildren(showHidden: Bool, gitIgnoreChecker: GitIgnoreChecker?) -> [FileTreeNode] {
        guard isDirectory else { return [] }

        do {
            // Foundation won't enumerate a symlinked directory via the link's
            // own URL (POSIX "Not a directory"), so scan the resolved target.
            // Children are rebased back under `url` below, keeping the whole
            // tree — and the gitignore/reveal path prefixes — in the display
            // root's path-space.
            let scanURL = url.resolvingSymlinksInPath()
            let contents = try FileManager.default.contentsOfDirectory(
                at: scanURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
                options: [.skipsPackageDescendants]
            )

            // Read the (already-fetched) resource values once per entry
            // instead of stat-ing inside the sort comparator and again in
            // each child node's initializer.
            let entries: [(url: URL, isDirectory: Bool)] = contents
                .map { childURL in
                    let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    var isDir = values?.isDirectory ?? false
                    // isDirectoryKey describes the link itself, so a symlink to
                    // a directory reads as a file and can never be expanded.
                    // Resolve links the way Finder does (pnpm node_modules and
                    // build trees are full of them); fileExists follows the
                    // link and is false for broken ones.
                    if !isDir, values?.isSymbolicLink == true {
                        var resolvedIsDir: ObjCBool = false
                        isDir = FileManager.default.fileExists(atPath: childURL.path, isDirectory: &resolvedIsDir)
                            && resolvedIsDir.boolValue
                    }
                    // Rebase entries scanned via a resolved symlink back under
                    // this node's URL (identical when no link was involved).
                    let rebased = scanURL == url
                        ? childURL
                        : url.appendingPathComponent(childURL.lastPathComponent, isDirectory: isDir)
                    return (rebased, isDir)
                }
                .sorted { lhs, rhs in
                    // Directories first, then alphabetical
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
                }

            var newChildren: [FileTreeNode] = []
            for entry in entries {
                let child = FileTreeNode(url: entry.url, parent: self, isDirectory: entry.isDirectory)

                // Skip hidden files if not showing hidden
                if child.isHidden && !showHidden {
                    continue
                }

                // Check git ignore status
                if let checker = gitIgnoreChecker {
                    child.isGitIgnored = checker.isIgnored(path: entry.url.path)
                    if child.isGitIgnored && !showHidden {
                        continue
                    }
                }

                newChildren.append(child)
            }

            return newChildren
        } catch {
            Log.error("Error loading directory contents for \(url.path): \(error)", category: "sidebar")
            return []
        }
    }

    /// Publishes scanned children onto a node that is already part of the live
    /// tree. MUST run on the main thread: `children`/`isLoaded` are read by
    /// AppKit's data source there, so the live tree is only mutated on main.
    func commitChildren(_ newChildren: [FileTreeNode]) {
        dispatchPrecondition(condition: .onQueue(.main))
        children = newChildren
        isLoaded = true
    }

    /// Recursively builds this subtree, also loading any descendant directories
    /// whose paths are in `expandedPaths` (used to restore expansion on
    /// refresh). MUST only be called on a node that is still DETACHED from the
    /// live tree — the background mutation of `children`/`isLoaded` is safe
    /// precisely because no other thread can observe the node until it's
    /// published (by assigning it as `rootNode` on the main thread).
    func loadSubtree(expandedPaths: Set<String>, showHidden: Bool, gitIgnoreChecker: GitIgnoreChecker?) {
        guard isDirectory, !isLoaded else { return }

        let scanned = scanChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker)
        children = scanned
        isLoaded = true

        for child in scanned where child.isDirectory && expandedPaths.contains(child.url.path) {
            child.isExpanded = true
            child.loadSubtree(expandedPaths: expandedPaths, showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker)
        }
    }

    /// Whether `other` describes exactly what this subtree currently displays:
    /// same entry, same dimming flags (isHidden/isGitIgnored drive it), same
    /// loaded/expanded shape, and the same children in the same order. Used to
    /// drop a rebuild that would repaint identical rows — the common case, since
    /// an agent editing file *contents* doesn't change the listing.
    ///
    /// Unloaded directories compare equal without descending: they show no rows,
    /// and neither side has children to compare. Requiring `isLoaded` to match
    /// keeps a live subtree that the fresh scan wouldn't have loaded (a folder
    /// the user collapsed, whose cached children may now be stale) from
    /// surviving the skip. Pure — no I/O, no AppKit.
    func isStructurallyIdentical(to other: FileTreeNode) -> Bool {
        guard url.path == other.url.path,
              isDirectory == other.isDirectory,
              isHidden == other.isHidden,
              isGitIgnored == other.isGitIgnored,
              isExpanded == other.isExpanded,
              isLoaded == other.isLoaded,
              children.count == other.children.count else { return false }

        for (lhs, rhs) in zip(children, other.children) where !lhs.isStructurallyIdentical(to: rhs) {
            return false
        }

        return true
    }

    var path: String {
        return url.path
    }

    var relativePath: String? {
        guard let parent = parent else { return nil }
        if let parentPath = parent.relativePath {
            return parentPath + "/" + name
        } else {
            return name
        }
    }
}
