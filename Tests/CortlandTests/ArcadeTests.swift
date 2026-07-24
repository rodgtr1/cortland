import XCTest
import Cocoa
@testable import Cortland

@MainActor
final class BlocksGameTests: XCTestCase {
    private let columns = BlocksGame.columns
    private let rows = BlocksGame.rows

    private func emptyBoard() -> [Int] {
        Array(repeating: -1, count: columns * rows)
    }

    /// Board with the given rows filled except at the listed columns.
    private func board(fillingRows filled: [Int], except gaps: [Int] = []) -> [Int] {
        var cells = emptyBoard()
        for row in filled {
            for column in 0..<columns where !gaps.contains(column) {
                cells[row * columns + column] = BlockPiece.o.rawValue
            }
        }
        return cells
    }

    private func makeGame(
        board: [Int],
        current: ActivePieceState?,
        nextQueue: [BlockPiece] = [.o, .t, .s],
        bag: [BlockPiece] = [.z, .j, .l],
        score: Int = 0,
        lines: Int = 0
    ) -> BlocksGame {
        BlocksGame(state: BlocksGameState(
            board: board,
            current: current,
            nextQueue: nextQueue,
            bag: bag,
            held: nil,
            canHold: true,
            score: score,
            lines: lines,
            isGameOver: false,
            pendingClearRows: nil
        ))
    }

    // MARK: - Setup and bag

    func testFreshGameDealsAllSevenPiecesFromOneBag() {
        let game = BlocksGame()
        let snapshot = game.snapshot()
        var dealt = snapshot.nextQueue + snapshot.bag
        if let current = snapshot.current {
            dealt.append(current.piece)
        }
        XCTAssertEqual(Set(dealt).count, 7, "first bag should hold each piece exactly once")
        XCTAssertEqual(dealt.count, 7)
        XCTAssertEqual(snapshot.current?.x, 3)
        XCTAssertEqual(snapshot.current?.y, 0)
        XCTAssertFalse(game.isGameOver)
    }

    func testBagRefillsWhenEmpty() {
        let game = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .t, rotation: 0, x: 3, y: 0),
            nextQueue: [.o, .t, .s],
            bag: []
        )
        game.hardDrop() // spawn consumes the queue head and must refill the bag
        let snapshot = game.snapshot()
        XCTAssertEqual(snapshot.nextQueue.count, 3)
        XCTAssertEqual(snapshot.bag.count, 6, "fresh 7-bag minus the piece appended to the queue")
        XCTAssertEqual(Set(snapshot.bag).count, 6)
    }

    // MARK: - Movement

    func testHorizontalMovementStopsAtWalls() {
        let game = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .o, rotation: 0, x: 3, y: 0)
        )
        // O occupies box columns 1-2, so piece.x can reach -1 (left wall)
        // and 7 (right wall).
        var moved = 0
        while game.moveLeft() { moved += 1 }
        XCTAssertEqual(game.current?.x, -1)
        XCTAssertEqual(moved, 4)

        while game.moveRight() {}
        XCTAssertEqual(game.current?.x, 7)
    }

    func testSoftDropScoresOnePointPerRow() {
        let game = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .o, rotation: 0, x: 3, y: 0)
        )
        game.softDrop()
        game.softDrop()
        XCTAssertEqual(game.score, 2)
        XCTAssertEqual(game.current?.y, 2)
    }

    func testHardDropLocksAndScoresTwoPointsPerRow() {
        let game = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .o, rotation: 0, x: 3, y: 0)
        )
        game.hardDrop()
        // O's cells sit at box rows 0-1, so it rests at y=18 (cells in rows 18/19).
        XCTAssertEqual(game.score, 2 * 18)
        XCTAssertEqual(game.board[19 * columns + 4], BlockPiece.o.rawValue)
        XCTAssertEqual(game.board[18 * columns + 4], BlockPiece.o.rawValue)
        // Next piece spawned from the queue head.
        XCTAssertEqual(game.current?.piece, .o)
        XCTAssertEqual(game.current?.y, 0)
    }

    // MARK: - Rotation

    func testRotationKicksOffTheLeftWall() {
        // Vertical I hugging the left wall: an unkicked rotation to horizontal
        // would poke through the wall; the kick table must shift it right.
        let game = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .i, rotation: 1, x: -2, y: 5)
        )
        game.rotate(clockwise: true)
        XCTAssertEqual(game.current?.rotation, 2)
        XCTAssertEqual(game.current?.x, 0, "kick should shift the piece inside the wall")
    }

    func testBlockedRotationIsRefused() {
        // Vertical I in a one-column shaft: no kick can make horizontal fit.
        var cells = emptyBoard()
        for row in 0..<rows {
            for column in 0..<columns where column != 0 {
                cells[row * columns + column] = BlockPiece.o.rawValue
            }
        }
        let game = makeGame(
            board: cells,
            current: ActivePieceState(piece: .i, rotation: 1, x: -2, y: 5)
        )
        game.rotate(clockwise: true)
        XCTAssertEqual(game.current?.rotation, 1, "rotation with no fitting kick must be refused")
        XCTAssertEqual(game.current?.x, -2)
    }

    // MARK: - Line clears and scoring

    func testSingleLineClearScoresHundredTimesLevel() {
        // Bottom row full except column 0; a vertical I dropped into the gap
        // completes it.
        let game = makeGame(
            board: board(fillingRows: [19], except: [0]),
            current: ActivePieceState(piece: .i, rotation: 1, x: -2, y: 0)
        )
        game.hardDrop()

        // Locking enters the clearing phase (for the view's flash animation):
        // the full row is detected but not yet collapsed or scored.
        XCTAssertEqual(game.pendingClearRows, [19])
        XCTAssertNil(game.current, "no piece falls during the clearing phase")
        XCTAssertEqual(game.score, 32, "only the hard-drop points land before the collapse")
        XCTAssertEqual(game.lines, 0)

        game.finishClearing()
        XCTAssertNil(game.pendingClearRows)
        XCTAssertEqual(game.lines, 1)
        // 2 points x 16 rows of hard drop + 100 x level 1.
        XCTAssertEqual(game.score, 32 + 100)
        // The I's three remaining cells shift down one row into 17-19.
        XCTAssertEqual(game.board[19 * columns + 0], BlockPiece.i.rawValue)
        XCTAssertEqual(game.board[17 * columns + 0], BlockPiece.i.rawValue)
        XCTAssertEqual(game.board[16 * columns + 0], -1)
        // The filler cells of the cleared row are gone.
        XCTAssertEqual(game.board[19 * columns + 5], -1)
    }

    func testTetrisClearScoresEightHundred() {
        let game = makeGame(
            board: board(fillingRows: [16, 17, 18, 19], except: [0]),
            current: ActivePieceState(piece: .i, rotation: 1, x: -2, y: 0)
        )
        game.hardDrop()
        XCTAssertEqual(game.pendingClearRows, [16, 17, 18, 19])

        game.finishClearing()
        XCTAssertEqual(game.lines, 4)
        XCTAssertEqual(game.score, 2 * 16 + 800)
        XCTAssertEqual(game.board.filter { $0 >= 0 }.count, 0, "board should be empty after a perfect tetris")
    }

    func testClearingPhaseIsInertUntilFinished() throws {
        let game = makeGame(
            board: board(fillingRows: [19], except: [0]),
            current: ActivePieceState(piece: .i, rotation: 1, x: -2, y: 0)
        )
        game.hardDrop()

        // Mid-clear, every input and gravity tick is a no-op, and the state
        // survives a save/restore round trip (e.g. quitting during the flash).
        let pending = game.snapshot()
        game.moveLeft()
        game.tick()
        game.hardDrop()
        game.hold()
        XCTAssertEqual(game.snapshot(), pending)

        let restored = BlocksGame(state: try JSONDecoder().decode(
            BlocksGameState.self,
            from: JSONEncoder().encode(pending)
        ))
        restored.finishClearing()
        XCTAssertEqual(restored.lines, 1)
        XCTAssertNotNil(restored.current, "the next piece spawns once the clear finishes")

        // finishClearing with nothing pending is a no-op.
        let after = restored.snapshot()
        restored.finishClearing()
        XCTAssertEqual(restored.snapshot(), after)
    }

    func testLevelAdvancesEveryTenLinesAndSpeedsGravity() {
        let fresh = BlocksGame()
        XCTAssertEqual(fresh.level, 1)

        let leveled = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .o, rotation: 0, x: 3, y: 0),
            lines: 30
        )
        XCTAssertEqual(leveled.level, 4)
        XCTAssertLessThan(leveled.gravityInterval, fresh.gravityInterval)
        XCTAssertGreaterThanOrEqual(leveled.gravityInterval, 0.06)
    }

    // MARK: - Hold

    func testHoldStashesPieceAndAllowsOneSwapPerLock() {
        let game = makeGame(
            board: emptyBoard(),
            current: ActivePieceState(piece: .t, rotation: 0, x: 3, y: 5)
        )
        game.hold()
        XCTAssertEqual(game.held, .t)
        XCTAssertEqual(game.current?.piece, .o, "queue head spawns when nothing was held")
        XCTAssertEqual(game.current?.y, 0)

        game.hold()
        XCTAssertEqual(game.held, .t, "second hold before locking must be a no-op")
        XCTAssertEqual(game.current?.piece, .o)

        game.hardDrop()
        game.hold()
        XCTAssertEqual(game.current?.piece, .t, "previously held piece swaps back in after a lock")
    }

    // MARK: - Game over

    func testSpawnIntoOccupiedCellsEndsTheGame() {
        // Spawn area blocked: locking the current piece must flip game over.
        // The gap in column 9 keeps rows 0-1 from counting as full lines.
        let game = makeGame(
            board: board(fillingRows: [0, 1], except: [9]),
            current: ActivePieceState(piece: .o, rotation: 0, x: 3, y: 17)
        )
        game.hardDrop()
        XCTAssertTrue(game.isGameOver)

        // All inputs are inert once the game is over.
        let before = game.snapshot()
        game.moveLeft()
        game.softDrop()
        game.rotate(clockwise: true)
        game.hold()
        game.tick()
        XCTAssertEqual(game.snapshot(), before)
    }

    // MARK: - Persistence

    func testSnapshotRoundTripsThroughCodable() throws {
        let game = BlocksGame()
        game.moveRight()
        game.softDrop()
        game.hold()

        let snapshot = game.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BlocksGameState.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(BlocksGame(state: decoded).snapshot(), snapshot)
    }
}

@MainActor
final class ArcadeStateStoreTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("arcade-tests-\(UUID().uuidString)")
            .appendingPathComponent("arcade.json")
    }

    func testSaveAndLoadRoundTrip() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let state = ArcadeSaveFile(
            selectedGameID: "blocks",
            gameStates: ["blocks": Data("blob".utf8)]
        )
        ArcadeStateStore.save(state, to: fileURL)
        XCTAssertEqual(ArcadeStateStore.load(from: fileURL), state)
    }

    func testLoadReturnsNilForMissingOrCorruptFile() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        XCTAssertNil(ArcadeStateStore.load(from: fileURL))

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(ArcadeStateStore.load(from: fileURL))
    }

    func testBlocksGameViewStateSurvivesEncodeDecode() throws {
        let view = BlocksGameView(savedState: nil)
        guard let blob = view.encodeState() else {
            return XCTFail("fresh game should still encode (it carries the high score)")
        }
        let restored = BlocksGameView(savedState: blob)
        guard let reEncoded = restored.encodeState() else {
            return XCTFail("restored game should encode")
        }
        // Compare parsed JSON, not raw bytes: key order isn't guaranteed.
        let original = try JSONSerialization.jsonObject(with: blob) as? NSDictionary
        let roundTripped = try JSONSerialization.jsonObject(with: reEncoded) as? NSDictionary
        XCTAssertEqual(roundTripped, original, "restoring a snapshot and re-encoding must be lossless")
    }
}

@MainActor
final class ArcadeRoutingAndConfigTests: XCTestCase {
    private let router = KeyboardCommandRouter()

    private func route(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> KeyboardCommand? {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Could not construct key event")
            return nil
        }
        return router.command(for: event, tabCount: 1)
    }

    func testControlBacktickTogglesArcade() {
        XCTAssertEqual(route(50, .control), .toggleArcade)
    }

    func testBacktickWithOtherModifiersDoesNotToggleArcade() {
        XCTAssertNil(route(50, []))
        XCTAssertNil(route(50, .command))
        XCTAssertNil(route(50, [.control, .shift]))
    }

    func testArcadeConfigDefaultsToDisabled() {
        XCTAssertFalse(ArcadeConfig().enabled)
        XCTAssertEqual(Config().arcade?.enabled, false)
    }

    func testToggleArcadeHasDisplayShortcut() {
        XCTAssertEqual(KeyboardCommand.toggleArcade.displayShortcut, "⌃`")
    }
}
