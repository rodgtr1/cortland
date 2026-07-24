import XCTest
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
}
