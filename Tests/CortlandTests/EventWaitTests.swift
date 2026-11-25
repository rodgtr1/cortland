import XCTest
import os
import CortlandIPCCore
@testable import Cortland

/// Covers the F2 wait-event plumbing: the broadcaster's backlog-skip mode and
/// the client-side deadline-bounded line wait behind `cortland_wait_event`.
final class EventWaitTests: XCTestCase {

    private func event(_ type: String, pane: String, state: String? = nil) -> CortlandEvent {
        var event = CortlandEvent(type: type)
        event.paneID = pane
        event.state = state
        return event
    }

    /// Registers a subscriber over one end of a socketpair and returns the
    /// JSONL lines written to it, first synchronously on subscribe, then after
    /// running `afterSubscribe`.
    private func subscribeAndCollect(
        _ broadcaster: EventBroadcaster,
        includeBacklog: Bool,
        afterSubscribe: (EventBroadcaster) -> Void = { _ in }
    ) -> [String] {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        broadcaster.addSubscriber(fds[0], includeBacklog: includeBacklog)
        afterSubscribe(broadcaster)

        // Everything above wrote synchronously; drain whatever is buffered.
        let flags = fcntl(fds[1], F_GETFL, 0)
        _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fds[1], &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        broadcaster.removeSubscriber(fds[0])   // closes fds[0]
        close(fds[1])
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    func testSubscribeReplaysBacklogByDefault() {
        let broadcaster = EventBroadcaster()
        broadcaster.emit(event("agent_state", pane: "a", state: "working"))

        let lines = subscribeAndCollect(broadcaster, includeBacklog: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"hello\""))
        XCTAssertTrue(lines[1].contains("\"working\""))
    }

    func testSubscribeWithoutBacklogOnlyGreetsThenStreamsLive() {
        let broadcaster = EventBroadcaster()
        broadcaster.emit(event("agent_state", pane: "a", state: "working"))

        let lines = subscribeAndCollect(broadcaster, includeBacklog: false) {
            $0.emit(self.event("agent_state", pane: "a", state: "ready"))
        }
        // The pre-subscribe "working" state is not replayed; the live "ready"
        // transition still arrives.
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"hello\""))
        XCTAssertTrue(lines[1].contains("\"ready\""))
        XCTAssertFalse(lines.contains { $0.contains("\"working\"") })
    }

    func testEventsCommandDecodesBacklogFlag() throws {
        let json = #"{"action": "events", "backlog": false, "type": "agent_state"}"#
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command.backlog, false)

        let bare = try JSONDecoder().decode(IPCCommand.self, from: Data(#"{"action": "events"}"#.utf8))
        XCTAssertNil(bare.backlog)
    }

    // MARK: - waitForLine against a real unix socket

    /// A one-connection unix-socket server: accepts, then runs `serve` with
    /// the connected fd on a background thread.
    private func withMiniServer(
        serve: @escaping @Sendable (Int32) -> Void,
        test: (CortlandIPCClient) -> Void
    ) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-wait-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThan(path.utf8CString.count, maxPathLength)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = strncpy(destination, source, maxPathLength - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)

        let acceptor = Thread {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            // Consume the subscribe request line before serving.
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &buffer, buffer.count)
            serve(client)
            close(client)
        }
        acceptor.start()

        test(CortlandIPCClient(socketPath: path))
    }

    func testWaitForLineReturnsFirstAcceptedLine() throws {
        try withMiniServer(serve: { fd in
            let payload = "{\"type\":\"hello\"}\n{\"type\":\"agent_state\",\"state\":\"done\"}\n"
            _ = payload.withCString { write(fd, $0, strlen($0)) }
            // Hold the connection open: the match, not a hangup, must end the wait.
            Thread.sleep(forTimeInterval: 2)
        }, test: { client in
            let outcome = client.waitForLine(["action": "events"], timeoutMS: 5000) { line in
                !String(decoding: line, as: UTF8.self).contains("hello")
            }
            guard case .matched(let line) = outcome else {
                return XCTFail("expected .matched, got \(outcome)")
            }
            XCTAssertTrue(String(decoding: line, as: UTF8.self).contains("agent_state"))
        })
    }

    /// The edit-gate hook parks at the approval desk, where the app treats EOF
    /// on the client socket as the hook having exited. With the half-close off,
    /// the server must not see EOF/hang-up while the request waits.
    func testSendWithoutHalfCloseLeavesNoEOFForServer() throws {
        let sawHangup = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        try withMiniServer(serve: { fd in
            // Same check as IPCServer.watchForClientDrop.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 300)
            var hungUp = false
            if ready > 0 {
                hungUp = (pfd.revents & Int16(POLLHUP | POLLERR)) != 0
                if !hungUp && (pfd.revents & Int16(POLLIN)) != 0 {
                    var byte: UInt8 = 0
                    hungUp = recv(fd, &byte, 1, Int32(MSG_PEEK)) <= 0
                }
            }
            let result = hungUp
            sawHangup.withLock { $0 = result }
            let reply = "{\"ok\":true,\"accepted\":true}\n"
            _ = reply.withCString { write(fd, $0, strlen($0)) }
        }, test: { client in
            let response = client.send(["action": "show_diff"], halfCloseWrite: false)
            XCTAssertEqual(response?["ok"] as? Bool, true)
            XCTAssertEqual(response?["accepted"] as? Bool, true)
        })
        XCTAssertEqual(sawHangup.withLock { $0 }, false, "server saw EOF/hang-up from a client still waiting for its reply")
    }

    func testWaitForLineTimesOutOnSilentStream() throws {
        try withMiniServer(serve: { fd in
            _ = "{\"type\":\"hello\"}\n".withCString { write(fd, $0, strlen($0)) }
            Thread.sleep(forTimeInterval: 3)   // silence past the client deadline
        }, test: { client in
            let started = Date()
            let outcome = client.waitForLine(["action": "events"], timeoutMS: 300) { _ in false }
            guard case .timedOut = outcome else {
                return XCTFail("expected .timedOut, got \(outcome)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        })
    }

    func testWaitForLineReportsServerHangup() throws {
        try withMiniServer(serve: { _ in
            // Close immediately: no lines, no timeout — a hangup.
        }, test: { client in
            let outcome = client.waitForLine(["action": "events"], timeoutMS: 5000) { _ in true }
            guard case .disconnected = outcome else {
                return XCTFail("expected .disconnected, got \(outcome)")
            }
        })
    }

    // MARK: Stalled subscriber

    private func setBufferSizes(_ fds: [Int32], _ size: Int32) {
        var value = size
        let length = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &value, length)
        setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, &value, length)
    }

    /// A subscriber whose peer never reads must be dropped once its buffer is
    /// full, without the emitting call blocking in write() for it, while a
    /// draining subscriber keeps getting every line.
    func testStalledSubscriberIsDroppedWithoutBlockingEmit() throws {
        let broadcaster = EventBroadcaster()
        var stalled: [Int32] = [0, 0]
        var draining: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &stalled), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &draining), 0)
        var noSigpipe: Int32 = 1
        for fd in [stalled[0], draining[0]] {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        }
        // Small buffers for the stalled one so a line soon outgrows the space
        // left; ample ones for the draining one so it never fills.
        setBufferSizes(stalled, 8_192)
        setBufferSizes(draining, 1_048_576)

        broadcaster.addSubscriber(stalled[0], includeBacklog: false)
        broadcaster.addSubscriber(draining[0], includeBacklog: false)

        let drainerPeer = draining[1]
        let drained = expectation(description: "draining subscriber read every line")
        let lineCount = 40
        let drainBox = DrainBox()
        Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var data = Data()
            while true {
                let count = read(drainerPeer, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
                // hello + every emitted line
                if data.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) >= lineCount + 1 { break }
            }
            drainBox.set(data)
            drained.fulfill()
        }.start()

        // Each line is larger than what an 8KB buffer has left after one of
        // them, so a blocking write would stall here until the peer reads.
        let emitted = expectation(description: "emit returned")
        Thread {
            for index in 0..<lineCount {
                var event = CortlandEvent(type: "command")
                event.paneID = "p"
                event.command = String(repeating: "x", count: 6_000) + " \(index)"
                broadcaster.emit(event)
            }
            emitted.fulfill()
        }.start()

        // Bounded, so a regression fails instead of hanging the suite.
        let result = XCTWaiter.wait(for: [emitted, drained], timeout: 5)
        defer {
            broadcaster.removeSubscriber(stalled[0])
            broadcaster.removeSubscriber(draining[0])
            close(stalled[1])
            close(draining[1])
        }
        // Closing the stalled peer first unblocks a regressed write so the
        // emitting thread can exit.
        if result != .completed { close(stalled[1]); stalled[1] = -1 }
        XCTAssertEqual(result, .completed, "emit blocked on a subscriber that stopped reading")

        let drainedLines = String(decoding: drainBox.get(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(drainedLines.count, lineCount + 1)
        XCTAssertTrue(drainedLines.last?.contains("x \(lineCount - 1)\"") ?? false)

        // The stalled one got some lines, then was dropped: its buffered bytes
        // read out and then EOF (the broadcaster shut it down), not EAGAIN.
        guard stalled[1] >= 0 else { return }
        let flags = fcntl(stalled[1], F_GETFL, 0)
        _ = fcntl(stalled[1], F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var stalledData = Data()
        var sawEOF = false
        while true {
            let count = read(stalled[1], &buffer, buffer.count)
            if count == 0 { sawEOF = true; break }
            if count < 0 { break }
            stalledData.append(contentsOf: buffer[0..<count])
        }
        XCTAssertTrue(sawEOF, "stalled subscriber was not dropped")
        let stalledLines = stalledData.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        XCTAssertGreaterThanOrEqual(stalledLines, 1, "it received lines before its buffer filled")
        XCTAssertLessThan(stalledLines, lineCount + 1)
    }
}

/// Hands the drainer thread's bytes back to the test.
private final class DrainBox: Sendable {
    private let data = OSAllocatedUnfairLock(initialState: Data())
    func set(_ value: Data) { data.withLock { $0 = value } }
    func get() -> Data { data.withLock { $0 } }
}
