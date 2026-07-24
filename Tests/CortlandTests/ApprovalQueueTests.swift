import XCTest
import AppKit
@testable import Cortland

@MainActor
private final class StubApprovalHost: DiffApprovalHost {
    var shouldAutoApproveEdits = false
    var approvalConfig = ApprovalConfig()
    var automationWindow: NSWindow?
    var paneWorkingDirectories: [UUID?: String] = [:]
    func workingDirectory(forPane paneID: UUID?) -> String? { paneWorkingDirectories[paneID] }
}

@MainActor
final class ApprovalQueueTests: XCTestCase {
    func testResolveRunsCompletionOnceAndRemovesEntry() {
        let queue = ApprovalQueue()
        var outcomes: [ApprovalOutcome] = []
        queue.enqueue(paneID: nil, path: "/tmp/a.txt", old: "", new: "x") { outcomes.append($0) }

        XCTAssertEqual(queue.pending.count, 1)
        let id = queue.pending[0].id

        queue.resolve(id: id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].accepted)

        // A second resolve for the same id (click racing a drain) is a no-op.
        queue.resolve(id: id, outcome: .rejected)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testDrainAllDecidesPerEntryAndEmptiesQueue() {
        let queue = ApprovalQueue()
        var results: [String: Bool] = [:]
        queue.enqueue(paneID: nil, path: "/tmp/open.txt", old: "", new: "x") { results["open"] = $0.accepted }
        queue.enqueue(paneID: nil, path: "/tmp/closed.env", old: "", new: "x") { results["closed"] = $0.accepted }

        queue.drainAll { entry in
            ApprovalOutcome(accepted: !entry.path.hasSuffix(".env"), remember: .none)
        }

        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(results["open"], true)
        XCTAssertEqual(results["closed"], false)
    }

    func testCountForPaneOnlyCountsThatPane() {
        let queue = ApprovalQueue()
        let paneA = UUID(), paneB = UUID()
        queue.enqueue(paneID: paneA, path: "/tmp/a.txt", old: "", new: "x") { _ in }
        queue.enqueue(paneID: paneA, path: "/tmp/b.txt", old: "", new: "x") { _ in }
        queue.enqueue(paneID: paneB, path: "/tmp/c.txt", old: "", new: "x") { _ in }

        XCTAssertEqual(queue.count(forPane: paneA), 2)
        XCTAssertEqual(queue.count(forPane: paneB), 1)
        XCTAssertEqual(queue.count(forPane: nil), 0)
    }

    func testWithdrawRemovesEntryWithoutFiringCompletion() {
        let queue = ApprovalQueue()
        var fired = false
        let id = queue.enqueue(paneID: nil, path: "/tmp/gone.txt", old: "", new: "x") { _ in fired = true }

        let withdrawn = queue.withdraw(id: id)
        XCTAssertEqual(withdrawn?.path, "/tmp/gone.txt")
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertFalse(fired, "a withdrawn entry drops its held completion unfired — the socket is dead")

        // A resolve racing the withdrawal (or a second withdraw) is a no-op.
        queue.resolve(id: id, outcome: .rejected)
        XCTAssertNil(queue.withdraw(id: id))
        XCTAssertFalse(fired)
    }

    func testEnqueueCarriesAlwaysAskFlag() {
        let queue = ApprovalQueue()
        queue.enqueue(paneID: nil, path: "/tmp/.env", old: "", new: "x", isAlwaysAsk: true) { _ in }
        queue.enqueue(paneID: nil, path: "/tmp/a.txt", old: "", new: "x") { _ in }
        XCTAssertTrue(queue.pending[0].isAlwaysAsk)
        XCTAssertFalse(queue.pending[1].isAlwaysAsk, "default is false when not an always_ask path")
    }

    func testEnqueueAndResolvePostChangeNotifications() {
        let queue = ApprovalQueue()
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .pendingApprovalsChanged, object: queue, queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        queue.enqueue(paneID: nil, path: "/tmp/a.txt", old: "", new: "x") { _ in }
        XCTAssertEqual(counter.value, 1)
        queue.resolve(id: queue.pending[0].id, outcome: .rejected)
        XCTAssertEqual(counter.value, 2)
    }
}

@MainActor
final class DiffApprovalCoordinatorQueueTests: XCTestCase {
    private final class Recorder {
        var lines: [String] = []
        /// Net parked count per pane, driven by onParkedStatusChange.
        var parked: [UUID: Int] = [:]
    }

    private func makeCoordinator(
        host: StubApprovalHost,
        queue: ApprovalQueue
    ) -> (DiffApprovalCoordinator, recorder: Recorder) {
        let recorder = Recorder()
        let coordinator = DiffApprovalCoordinator(
            host: host,
            queue: queue,
            onParkedStatusChange: { paneID, parked in
                recorder.parked[paneID, default: 0] += parked ? 1 : -1
            }
        ) { path, decision in
            recorder.lines.append("\(decision):\((path as NSString).lastPathComponent)")
        }
        return (coordinator, recorder)
    }

    /// Drains the main queue so the disconnect handler's async hop to main (the
    /// real path runs it off a background watcher thread) actually executes
    /// before the assertions read the result.
    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testAutoApproveBypassesQueue() {
        let host = StubApprovalHost()
        host.shouldAutoApproveEdits = true
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, recorder) = makeCoordinator(host: host, queue: queue)

        var accepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/auto.txt", old: "", new: "x") { accepted = $0 }

        XCTAssertEqual(accepted, true)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(recorder.lines, ["accepted:auto.txt"])
        XCTAssertTrue(recorder.parked.isEmpty, "a silent allow never parks, so it never flips status")
    }

    func testAskModeParksInQueueUntilResolved() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, recorder) = makeCoordinator(host: host, queue: queue)

        var accepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/ask.txt", old: "", new: "x") { accepted = $0 }

        XCTAssertNil(accepted)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(recorder.lines, ["pending:ask.txt"])

        queue.resolve(id: queue.pending[0].id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(recorder.lines, ["pending:ask.txt", "accepted:ask.txt"])
    }

    func testParkedEntryFlipsPaneStatusToNeedsInputAndBack() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, recorder) = makeCoordinator(host: host, queue: queue)
        let pane = UUID()

        coordinator.requestApproval(paneID: pane, path: "/tmp/ask.txt", old: "", new: "x") { _ in }
        XCTAssertEqual(recorder.parked[pane], 1, "an edit waiting at the desk flips the pane to needs input")

        queue.resolve(id: queue.pending[0].id, outcome: .rejected)
        XCTAssertEqual(recorder.parked[pane], 0, "resolving returns the pane to working")
    }

    func testUnscopedParkedEntryFlipsNoPaneStatus() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, recorder) = makeCoordinator(host: host, queue: queue)

        // A hook that reported no pane has nothing to flip.
        coordinator.requestApproval(paneID: nil, path: "/tmp/ask.txt", old: "", new: "x") { _ in }
        XCTAssertTrue(recorder.parked.isEmpty)
    }

    func testClientDropWithdrawsEntryAndReturnsPaneToWorking() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, recorder) = makeCoordinator(host: host, queue: queue)
        let pane = UUID()

        var resolved: Bool?
        var disconnect: (@Sendable () -> Void)?
        coordinator.requestApproval(
            paneID: pane, path: "/tmp/ask.txt", old: "", new: "x",
            registerDisconnect: { disconnect = $0 }
        ) { resolved = $0 }

        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(recorder.parked[pane], 1)

        // The hook process dies at the desk: the server-side drop handler fires.
        disconnect?()
        drainMainQueue()
        XCTAssertTrue(queue.pending.isEmpty, "the orphaned entry withdraws")
        XCTAssertNil(resolved, "no accept/reject reaches the dead socket")
        XCTAssertEqual(recorder.lines, ["pending:ask.txt", "withdrawn:ask.txt"])
        XCTAssertEqual(recorder.parked[pane], 0, "the withdrawn pane returns to working")
    }

    func testClientDropAfterResolveIsNoOp() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, recorder) = makeCoordinator(host: host, queue: queue)
        let pane = UUID()

        var disconnect: (@Sendable () -> Void)?
        coordinator.requestApproval(
            paneID: pane, path: "/tmp/ask.txt", old: "", new: "x",
            registerDisconnect: { disconnect = $0 }
        ) { _ in }

        queue.resolve(id: queue.pending[0].id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        XCTAssertEqual(recorder.parked[pane], 0)

        // A drop that lands after a human already answered must not re-withdraw
        // or double-flip the status.
        disconnect?()
        drainMainQueue()
        XCTAssertEqual(recorder.lines, ["pending:ask.txt", "accepted:ask.txt"])
        XCTAssertEqual(recorder.parked[pane], 0)
    }

    func testAlwaysAskEntryIsFlaggedOnTheQueue() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        host.approvalConfig.alwaysAsk = [".env"]
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)

        coordinator.requestApproval(paneID: nil, path: "/tmp/.env", old: "", new: "x") { _ in }
        coordinator.requestApproval(paneID: nil, path: "/tmp/a.txt", old: "", new: "x") { _ in }
        XCTAssertTrue(queue.pending[0].isAlwaysAsk, "an always_ask path is flagged so its card hides the remember popup")
        XCTAssertFalse(queue.pending[1].isAlwaysAsk)
    }

    func testNoWindowFailsOpenExceptAlwaysAsk() {
        let host = StubApprovalHost()
        host.automationWindow = nil
        host.approvalConfig.alwaysAsk = [".env"]
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)

        var plainAccepted: Bool?
        var secretAccepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/plain.txt", old: "", new: "x") { plainAccepted = $0 }
        coordinator.requestApproval(paneID: nil, path: "/tmp/.env", old: "", new: "x") { secretAccepted = $0 }

        XCTAssertEqual(plainAccepted, true)
        XCTAssertEqual(secretAccepted, false)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testWindowCloseDrainFailsOpenExceptAlwaysAsk() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        host.approvalConfig.alwaysAsk = [".env"]
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)

        var plainAccepted: Bool?
        var secretAccepted: Bool?
        coordinator.requestApproval(paneID: nil, path: "/tmp/plain.txt", old: "", new: "x") { plainAccepted = $0 }
        coordinator.requestApproval(paneID: nil, path: "/tmp/.env", old: "", new: "x") { secretAccepted = $0 }
        XCTAssertEqual(queue.pending.count, 2)

        coordinator.prepareForWindowClose()
        XCTAssertEqual(plainAccepted, true)
        XCTAssertEqual(secretAccepted, false)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testRememberGrantAutoResolvesQueuedEditsItCovers() {
        let host = StubApprovalHost()
        host.automationWindow = NSWindow()
        let queue = ApprovalQueue()
        let (coordinator, _) = makeCoordinator(host: host, queue: queue)
        let pane = UUID(), otherPane = UUID()

        var firstAccepted: Bool?
        var siblingAccepted: Bool?
        var otherPaneAccepted: Bool?
        coordinator.requestApproval(paneID: pane, path: "/tmp/proj/a.txt", old: "", new: "x") { firstAccepted = $0 }
        coordinator.requestApproval(paneID: pane, path: "/tmp/proj/b.txt", old: "", new: "x") { siblingAccepted = $0 }
        coordinator.requestApproval(paneID: otherPane, path: "/tmp/proj/c.txt", old: "", new: "x") { otherPaneAccepted = $0 }
        XCTAssertEqual(queue.pending.count, 3)

        // Approving the first with a folder grant should clear the same-pane
        // sibling in the same folder, but grants are per-pane: the other
        // pane's request keeps waiting.
        queue.resolve(id: queue.pending[0].id, outcome: ApprovalOutcome(accepted: true, remember: .folder))

        XCTAssertEqual(firstAccepted, true)
        XCTAssertEqual(siblingAccepted, true)
        XCTAssertNil(otherPaneAccepted)
        XCTAssertEqual(queue.pending.count, 1)
    }
}
