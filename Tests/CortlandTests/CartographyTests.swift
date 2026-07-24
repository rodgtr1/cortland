import Cocoa
import XCTest
@testable import Cortland

@MainActor
final class CartographyWorldTests: XCTestCase {
    func testWorldGenerationIsDeterministicPerSeed() {
        for seed: UInt64 in [1, 42, 9999, 0xABCDEF] {
            let a = CartographyWorld(seed: seed)
            let b = CartographyWorld(seed: seed)
            XCTAssertEqual(a.land, b.land, "same seed must produce the same coastline")
            XCTAssertEqual(a.ground, b.ground)
        }
    }

    func testLandFractionAndRegionsAcrossManySeeds() {
        for seed in UInt64(1)...80 {
            let world = CartographyWorld(seed: seed)
            let fraction = world.landFraction
            XCTAssertGreaterThanOrEqual(fraction, 0.25, "seed \(seed): too little land (\(fraction))")
            XCTAssertLessThanOrEqual(fraction, 0.55, "seed \(seed): too much land (\(fraction))")

            var interiorLand = false, interiorSea = false
            for y in 1..<(CartographyWorld.height - 1) {
                for x in 1..<(CartographyWorld.width - 1) {
                    if world.isLand(x, y) { interiorLand = true } else { interiorSea = true }
                }
            }
            XCTAssertTrue(interiorLand, "seed \(seed): no interior land")
            XCTAssertTrue(interiorSea, "seed \(seed): no interior sea")
        }
    }

    func testGroundIsSeaOffLandAndBandedOnLand() {
        let world = CartographyWorld(seed: 7)
        for y in 0..<CartographyWorld.height {
            for x in 0..<CartographyWorld.width {
                if world.isLand(x, y) {
                    XCTAssertNotEqual(world.groundAt(x, y), .sea, "land must carry an elevation band")
                } else {
                    XCTAssertEqual(world.groundAt(x, y), .sea)
                }
            }
        }
    }
}

@MainActor
final class CartographyModelTests: XCTestCase {
    /// The 3-wide corridor a radius-1 stroke should uncover along a path.
    private func expectedCorridor(_ path: [(x: Int, y: Int)]) -> Set<Int> {
        var cells = Set<Int>()
        for point in path {
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = point.x + dx, y = point.y + dy
                    if CartographyWorld.inBounds(x, y) {
                        cells.insert(CartographyWorld.index(x, y))
                    }
                }
            }
        }
        return cells
    }

    func testStrokeRevealsCorridorAndSpendsInkOnNewCellsOnly() {
        let model = CartographyModel(seed: 3)
        // A short straight path; radius 1 makes a 3-wide corridor.
        let path = CartographyModel.line(from: (10, 10), to: (13, 10))
        let expected = expectedCorridor(path)

        let newly = model.reveal(along: path)
        XCTAssertEqual(newly, expected.count, "every corridor cell is newly revealed")
        XCTAssertEqual(model.snapshot().revealed, expected)
        XCTAssertEqual(model.ink, CartographyModel.inkCapacity - expected.count,
                       "ink drops by exactly the cells uncovered")

        // Re-surveying the same ground costs nothing.
        let inkBefore = model.ink
        let again = model.reveal(along: path)
        XCTAssertEqual(again, 0, "already-drawn cells are free")
        XCTAssertEqual(model.ink, inkBefore)
    }

    func testDryPenRevealsNothingAndRefillsOnOpen() {
        let model = CartographyModel(seed: 5)
        // Spend all the ink on a long sweep.
        var y = 2
        while !model.isDry && y < CartographyWorld.height - 2 {
            model.reveal(along: CartographyModel.line(from: (2, y), to: (CartographyWorld.width - 3, y)))
            y += 2
        }
        XCTAssertTrue(model.isDry)
        let revealedWhenDry = model.snapshot().revealed
        let newly = model.reveal(along: CartographyModel.line(from: (2, 30), to: (30, 30)))
        XCTAssertEqual(newly, 0, "a dry pen draws nothing")
        XCTAssertEqual(model.snapshot().revealed, revealedWhenDry, "nothing new was revealed")

        model.refillInk()
        XCTAssertEqual(model.ink, CartographyModel.inkCapacity, "opening the sheet refills the pen")
    }

    func testInkRefillsOnRestore() throws {
        let model = CartographyModel(seed: 11)
        model.reveal(along: CartographyModel.line(from: (5, 5), to: (40, 5)))
        XCTAssertLessThan(model.ink, CartographyModel.inkCapacity)

        let restored = CartographyModel(state: model.snapshot())
        XCTAssertEqual(restored.ink, model.ink, "the blob preserves ink until the sheet is opened")
        restored.refillInk()
        XCTAssertEqual(restored.ink, CartographyModel.inkCapacity)
    }

    func testCoastlineExistsOnlyWhenBothSidesAreSurveyed() {
        let world = CartographyWorld(seed: 42)
        // Find a land cell with an orthogonal sea neighbor.
        var landCell: (x: Int, y: Int)?
        var seaNeighbor: (x: Int, y: Int)?
        outer: for y in 1..<(CartographyWorld.height - 1) {
            for x in 1..<(CartographyWorld.width - 1) where world.isLand(x, y) {
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where !world.isLand(nx, ny) {
                    landCell = (x, y); seaNeighbor = (nx, ny); break outer
                }
            }
        }
        guard let land = landCell, let sea = seaNeighbor else {
            return XCTFail("seed 42 should have a shoreline")
        }

        // Reveal only the land cell: with the sea side hidden it is not coast.
        var landOnly = CartographyModel.freshState(seed: 42)
        landOnly.revealed = [CartographyWorld.index(land.x, land.y)]
        let landModel = CartographyModel(state: landOnly)
        XCTAssertNotNil(landModel.glyph(land.x, land.y), "the land cell is drawn as some kind of land")
        XCTAssertNotEqual(landModel.glyph(land.x, land.y), .coast,
                          "a land cell whose sea neighbor is unrevealed is not yet coast")

        // Reveal the sea side too: now the coastline exists.
        var bothSides = landOnly
        bothSides.revealed.insert(CartographyWorld.index(sea.x, sea.y))
        let coastModel = CartographyModel(state: bothSides)
        XCTAssertEqual(coastModel.glyph(land.x, land.y), .coast,
                       "once both sides are drawn the shoreline appears")
    }

    func testNamingPlaceRenameAndPersistence() throws {
        let model = CartographyModel(seed: 8)
        let cell = CartographyWorld.index(20, 15)
        model.placeName(cell: cell, text: "  Still Bay  ")
        XCTAssertEqual(model.names.count, 1)
        XCTAssertEqual(model.nameAnchored(at: cell)?.text, "Still Bay", "names are trimmed, not otherwise touched")

        model.placeName(cell: cell, text: "")
        XCTAssertEqual(model.nameAnchored(at: cell)?.text, "Still Bay", "an empty name is ignored")

        model.placeName(cell: cell, text: "Quiet Bay")
        XCTAssertEqual(model.names.count, 1, "renaming the same anchor does not add a name")
        XCTAssertEqual(model.nameAnchored(at: cell)?.text, "Quiet Bay")

        let decoded = try JSONDecoder().decode(CartographyState.self, from: JSONEncoder().encode(model.snapshot()))
        XCTAssertEqual(decoded, model.snapshot())
        XCTAssertEqual(CartographyModel(state: decoded).nameAnchored(at: cell)?.text, "Quiet Bay")
    }

    func testStateRoundTripsThroughCodable() throws {
        let model = CartographyModel(seed: 100)
        model.reveal(along: CartographyModel.line(from: (8, 8), to: (30, 20)))
        model.placeName(cell: CartographyWorld.index(12, 12), text: "The Sound")
        model.setTitle("Northern Reach")

        let snapshot = model.snapshot()
        let decoded = try JSONDecoder().decode(CartographyState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(CartographyModel(state: decoded).snapshot(), snapshot)
    }

    func testProgressIsWordsAcrossThresholds() {
        let model = CartographyModel(seed: 2)
        XCTAssertEqual(model.progressDescription, "mostly uncharted")
        // Reveal a broad swath and confirm the words advance (never a number).
        for y in stride(from: 2, to: CartographyWorld.height - 2, by: 1) {
            model.refillInk()
            model.reveal(along: CartographyModel.line(from: (2, y), to: (CartographyWorld.width - 3, y)))
        }
        XCTAssertTrue(["roughly sketched", "well charted"].contains(model.progressDescription))
    }
}

@MainActor
final class CartographyViewTests: XCTestCase {
    private func makeViewInWindow() -> (CartographyView, NSWindow) {
        let view = CartographyView(savedState: nil)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return (view, window)
    }

    private func ink(of view: CartographyView) throws -> Int {
        let data = try XCTUnwrap(view.encodeState())
        return try JSONDecoder().decode(CartographyState.self, from: data).ink
    }

    /// Hiding the panel leaves the game view as first responder, so reopening
    /// never re-triggers becomeFirstResponder. The refill must instead follow
    /// the window becoming key, or a dry pen stays dry across visits and
    /// dragging silently does nothing.
    func testHostWindowBecomingKeyRefillsThePen() throws {
        let (view, window) = makeViewInWindow()

        // A click in the middle of the sheet is a pen stroke that spends ink.
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: view.frame.midX, y: view.frame.midY),
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: click)
        XCTAssertLessThan(try ink(of: view), CartographyModel.inkCapacity,
                          "a stroke on hidden ground spends ink")

        // The panel coming back (toggle, or clicking back into it) is a visit.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(try ink(of: view), CartographyModel.inkCapacity,
                       "reopening the arcade refills the pen")
    }

    /// Another window becoming key is not a visit to this sheet.
    func testOtherWindowsBecomingKeyDoNotRefill() throws {
        let (view, window) = makeViewInWindow()
        _ = window

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: view.frame.midX, y: view.frame.midY),
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: click)
        let spent = try ink(of: view)
        XCTAssertLessThan(spent, CartographyModel.inkCapacity)

        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        XCTAssertEqual(try ink(of: view), spent, "an unrelated window is not a visit")
    }
}

@MainActor
final class CartographyAtlasTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cartography-tests-\(UUID().uuidString)")
            .appendingPathComponent("atlas.md")
    }

    func testExportWritesHeaderFencedMapAndNames() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let rows = ["  ~~  ", " .*~  ", "  ^:  "]
        let names = [CartographyName(cell: 5, text: "Still Bay"), CartographyName(cell: 9, text: "Long Hill")]
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        CartographyAtlas.export(title: "Sheet I", mapRows: rows, names: names, date: date, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Atlas"), "first export lays down the header")
        XCTAssertTrue(content.contains("## Sheet I · \(CartographyAtlas.dayStamp(for: date))"))
        XCTAssertTrue(content.contains("```\n  ~~  \n .*~  \n  ^:  \n```"), "the map is fenced verbatim")
        XCTAssertTrue(content.contains("- Still Bay"))
        XCTAssertTrue(content.contains("- Long Hill"))
    }

    func testEachExportAppendsADatedSection() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        CartographyAtlas.export(title: "Sheet I", mapRows: ["~"], names: [],
                                date: Date(timeIntervalSince1970: 1_750_000_000), to: url)
        CartographyAtlas.export(title: "Sheet II", mapRows: ["."], names: [],
                                date: Date(timeIntervalSince1970: 1_750_100_000), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let sections = content.components(separatedBy: "## ").count - 1
        XCTAssertEqual(sections, 2, "each export appends its own dated section")
        XCTAssertTrue(content.contains("## Sheet I"))
        XCTAssertTrue(content.contains("## Sheet II"))
    }
}
