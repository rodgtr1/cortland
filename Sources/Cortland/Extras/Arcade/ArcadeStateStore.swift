import Foundation

/// Everything the arcade remembers across launches: which game was up and
/// each game's opaque state blob, keyed by `ArcadeGame.gameID`.
nonisolated struct ArcadeSaveFile: Codable, Equatable, Sendable {
    var selectedGameID: String?
    var gameStates: [String: Data]
}

/// arcade.json lives beside session.json and follows the same shape of
/// best-effort persistence: absent or unreadable simply means "nothing to
/// restore" — losing a paused game is annoying, not data loss, so no .bak
/// dance here.
enum ArcadeStateStore {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/arcade.json")
    }

    static func save(_ state: ArcadeSaveFile, to fileURL: URL = defaultFileURL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("failed to save arcade state: \(error)", category: "arcade")
        }
    }

    static func load(from fileURL: URL = defaultFileURL) -> ArcadeSaveFile? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(ArcadeSaveFile.self, from: data)
        } catch {
            Log.error("failed to decode arcade state: \(error)", category: "arcade")
            return nil
        }
    }
}
