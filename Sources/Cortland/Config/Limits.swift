import Foundation

public enum Limits {
    public static let maxFileSize: Int = 2 * 1024 * 1024 // 2MB
    public static let maxTabs: Int = 20
    public static let maxPanesPerTab: Int = 4
    public static let maxSearchResults: Int = 1000
    public static let maxRecentFiles: Int = 50
    public static let maxTaskHistory: Int = 100
    public static let maxGitDiffSize: Int = 10 * 1024 * 1024 // 10MB
    /// Cortland.log rotates to Cortland.log.1 past this size; one generation is
    /// kept. `nonisolated` because Log reads it from its own background queue,
    /// off the main actor this module defaults to.
    nonisolated public static let maxLogFileSize: Int = 5 * 1024 * 1024 // 5MB
    public static let terminalScrollback: Int = 10000
    public static let searchDebounceMs: Int = 200
    public static let cwdPollIntervalMs: Int = 1000

    public static let binaryFileExtensions: Set<String> = [
        "exe", "dll", "so", "dylib", "a", "o", "obj",
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar",
        "jpg", "jpeg", "png", "gif", "bmp", "ico", "webp", "svg",
        "mp3", "mp4", "avi", "mov", "mkv", "webm", "flv",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "ttf", "otf", "woff", "woff2", "eot",
        "db", "sqlite", "sqlite3"
    ]

    public static func isBinaryFile(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        return binaryFileExtensions.contains(ext)
    }

    public static func isFileTooLarge(path: String) -> Bool {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int else {
            return false
        }
        return fileSize > maxFileSize
    }
}