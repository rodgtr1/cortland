import XCTest
@testable import Cortland

final class ArcadeHelpTests: XCTestCase {
    @MainActor
    func testEveryCatalogGameHasHowToPlayDirections() {
        XCTAssertFalse(ArcadeGameCatalog.games.isEmpty)

        for entry in ArcadeGameCatalog.games {
            XCTAssertFalse(entry.howToPlay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(entry.title) is missing How to Play directions")
            XCTAssertTrue(entry.howToPlay.contains("Esc"),
                          "\(entry.title) directions should explain how to leave the game")
        }
    }
}
