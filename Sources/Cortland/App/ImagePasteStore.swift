import Foundation

/// Holds clipboard images pasted into terminals as PNG files. Everything
/// lives in one dedicated folder under the user's temp directory (which
/// macOS also purges on its own), and files older than a day are pruned at
/// every launch so pastes never accumulate.
nonisolated enum ImagePasteStore {
    private static let maxAge: TimeInterval = 24 * 60 * 60

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cortland-pastes", isDirectory: true)
    }

    static func store(png: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).png")
        try png.write(to: url)
        return url
    }

    /// Deletes pastes older than `maxAge`. Called once at launch, off the
    /// main thread.
    static func pruneOldFiles() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified = modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
