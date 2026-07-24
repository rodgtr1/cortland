import XCTest
@testable import Cortland

/// Feature P1: the pure trigger/gate/withdraw decisions behind native macOS
/// notifications, kept separate from the UNUserNotificationCenter plumbing in
/// NotificationCoordinator so they're testable without a live app.
@MainActor
final class NotificationPolicyTests: XCTestCase {

    /// A config with the master switch and every trigger on, so gate tests
    /// isolate the gating logic rather than the enablement checks.
    private func allOn(threshold: Int = 30, grace: Int = 0) -> NotificationsConfig {
        var n = NotificationsConfig()
        n.enabled = true
        n.needsInput = true
        n.finished = true
        n.commandFailed = true
        n.longRunningCommand = true
        n.longRunningThresholdSeconds = threshold
        n.backgroundGraceSeconds = grace
        return n
    }

    // MARK: - Trigger from agent-state transitions

    func testTransitionIntoReadyIsNeedsInput() {
        XCTAssertEqual(NotificationTrigger.forAgentTransition(from: .working, to: .ready), .needsInput)
    }

    func testTransitionIntoDoneIsFinished() {
        XCTAssertEqual(NotificationTrigger.forAgentTransition(from: .working, to: .done), .finished)
    }

    func testSameStateRaisesNothing() {
        // .paneAgentStateChanged fires on every detection, not just changes.
        XCTAssertNil(NotificationTrigger.forAgentTransition(from: .ready, to: .ready))
    }

    func testTransitionToWorkingOrIdleRaisesNothing() {
        XCTAssertNil(NotificationTrigger.forAgentTransition(from: .ready, to: .working))
        XCTAssertNil(NotificationTrigger.forAgentTransition(from: .done, to: .idle))
    }

    // MARK: - Withdrawal decisions

    func testAgentResumeResolvesNeedsInputAndFinished() {
        XCTAssertTrue(NotificationTrigger.needsInput.isResolvedByAgentTransition(to: .working))
        XCTAssertTrue(NotificationTrigger.needsInput.isResolvedByAgentTransition(to: .idle))
        XCTAssertTrue(NotificationTrigger.finished.isResolvedByAgentTransition(to: .working))
    }

    func testStillWaitingDoesNotResolve() {
        // ready -> done delivers a fresh notification instead of withdrawing.
        XCTAssertFalse(NotificationTrigger.needsInput.isResolvedByAgentTransition(to: .done))
        XCTAssertFalse(NotificationTrigger.needsInput.isResolvedByAgentTransition(to: .ready))
    }

    func testCommandTriggersUnaffectedByAgentState() {
        XCTAssertFalse(NotificationTrigger.commandFailed.isResolvedByAgentTransition(to: .working))
        XCTAssertFalse(NotificationTrigger.longRunningCommand.isResolvedByAgentTransition(to: .idle))
    }

    func testCommandAttentionClearOnlyResolvesFailedCommand() {
        XCTAssertTrue(NotificationTrigger.commandFailed.isResolvedByCommandAttentionClear)
        XCTAssertFalse(NotificationTrigger.needsInput.isResolvedByCommandAttentionClear)
        XCTAssertFalse(NotificationTrigger.longRunningCommand.isResolvedByCommandAttentionClear)
    }

    // MARK: - Enablement (master switch + per-trigger)

    func testDisabledMasterSuppressesEverything() {
        var n = allOn()
        n.enabled = false
        for trigger in NotificationTrigger.allCases {
            XCTAssertFalse(n.isEnabled(trigger))
            XCTAssertEqual(n.shouldDeliver(trigger, appIsActive: false, backgroundedFor: 100), .suppress)
        }
    }

    func testPerTriggerToggleRespected() {
        var n = allOn()
        n.commandFailed = false
        XCTAssertTrue(n.isEnabled(.needsInput))
        XCTAssertFalse(n.isEnabled(.commandFailed))
    }

    // MARK: - The active-app gate

    func testNeverDeliversWhileActive() {
        let n = allOn()
        for trigger in NotificationTrigger.allCases {
            XCTAssertEqual(n.shouldDeliver(trigger, appIsActive: true, backgroundedFor: nil), .suppress)
        }
    }

    // MARK: - needs-input fires immediately when inactive

    func testNeedsInputIgnoresGracePeriod() {
        let n = allOn(grace: 60)
        // Backgrounded for only 1s, well under the 60s grace, still delivers.
        XCTAssertEqual(n.shouldDeliver(.needsInput, appIsActive: false, backgroundedFor: 1), .deliver)
        // Even with no recorded background time (just went inactive).
        XCTAssertEqual(n.shouldDeliver(.needsInput, appIsActive: false, backgroundedFor: nil), .deliver)
    }

    // MARK: - completions/failures respect the grace period

    func testCompletionsWaitOutGracePeriod() {
        let n = allOn(grace: 30)
        for trigger in [NotificationTrigger.finished, .commandFailed, .longRunningCommand] {
            XCTAssertEqual(n.shouldDeliver(trigger, appIsActive: false, backgroundedFor: 10), .suppress,
                           "\(trigger) should wait out the grace period")
            XCTAssertEqual(n.shouldDeliver(trigger, appIsActive: false, backgroundedFor: 30), .deliver,
                           "\(trigger) should fire once grace elapsed")
        }
    }

    func testCompletionsSuppressedWithoutBackgroundTime() {
        let n = allOn(grace: 5)
        // No recorded background duration and a non-zero grace: can't confirm the
        // app has been away long enough, so suppress.
        XCTAssertEqual(n.shouldDeliver(.finished, appIsActive: false, backgroundedFor: nil), .suppress)
    }

    func testZeroGraceFiresWheneverInactive() {
        let n = allOn(grace: 0)
        XCTAssertEqual(n.shouldDeliver(.finished, appIsActive: false, backgroundedFor: 0), .deliver)
    }

    // MARK: - Long-running threshold

    func testLongRunningThreshold() {
        let n = allOn(threshold: 30)
        XCTAssertFalse(n.longRunningCommandQualifies(duration: 29.9))
        XCTAssertTrue(n.longRunningCommandQualifies(duration: 30))
        XCTAssertTrue(n.longRunningCommandQualifies(duration: 120))
    }

    func testNilDurationNeverQualifies() {
        let n = allOn()
        XCTAssertFalse(n.longRunningCommandQualifies(duration: nil))
    }
}
