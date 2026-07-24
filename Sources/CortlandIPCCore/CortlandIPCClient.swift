import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The Unix-socket path Cortland listens on: `$CORTLAND_SOCKET_PATH` when set
/// (Cortland exports it into every pane), else the default under `~/.config`.
public func defaultCortlandSocketPath() -> String {
    ProcessInfo.processInfo.environment["CORTLAND_SOCKET_PATH"]
        ?? NSString("~/.config/cortland/cortland.sock").expandingTildeInPath
}

/// Shared client for Cortland's control socket, used by `cortland-ctl`,
/// `cortland-mcp`, and `cortland-telemetry`. Previously each helper carried its
/// own near-identical copy of the connect/write/read plumbing — with subtle
/// drift (an fd leak on the path-too-long branch, and a read loop that stopped at
/// the first newline and so truncated multi-line replies like `pane_read`
/// scrollback). This is the single, correct implementation.
public final class CortlandIPCClient {
    private let socketPath: String

    public init(socketPath: String = defaultCortlandSocketPath()) {
        self.socketPath = socketPath
    }

    /// Connects and writes `command` as one newline-framed JSON line. When
    /// `halfCloseWrite` is true the write side is shut so the server sees EOF and
    /// replies (request/response); streaming callers keep it open so the server's
    /// read side can detect their disconnect. Returns the connected FD (the caller
    /// owns `close`) or nil — and never leaks the FD on a failure path.
    public func openConnection(_ command: [String: Any], halfCloseWrite: Bool) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // Convert a broken-pipe write into an EPIPE return instead of a SIGPIPE:
        // if Cortland closes the read side mid-`write` below, the default signal
        // would terminate the caller — fatal for the long-lived `cortland-mcp`
        // server. The write loop already treats a non-positive return as failure,
        // so EPIPE is handled gracefully. Darwin-only socket option; on Linux the
        // helpers ignore SIGPIPE process-wide instead.
        #if !canImport(Glibc)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8CString.count <= maxPathLength else { close(fd); return nil }
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, path, maxPathLength - 1)
                destination[maxPathLength - 1] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              var payload = try? JSONSerialization.data(withJSONObject: command) else { close(fd); return nil }
        payload.append(UInt8(ascii: "\n"))
        let wroteAll = payload.withUnsafeBytes { bytes -> Bool in
            guard var cursor = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let count = write(fd, cursor, remaining)
                guard count > 0 else { return false }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard wroteAll else { close(fd); return nil }
        if halfCloseWrite { shutdown(fd, SHUT_WR) }
        return fd
    }

    /// One request → one reply. The protocol is line-delimited: the server
    /// writes one JSON object (JSON escapes embedded newlines, so the payload
    /// itself never contains a raw one) terminated by "\n". Stop at that
    /// newline rather than waiting for EOF — EOF only arrives once *every*
    /// copy of the fd closes, and a pane shell forked while the request was in
    /// flight can hold an inherited copy for its whole lifetime, which would
    /// block the read here long after the reply fully arrived.
    public func send(_ command: [String: Any]) -> [String: Any]? {
        guard let fd = openConnection(command, halfCloseWrite: true) else { return nil }
        defer { close(fd) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16 * 1024 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }   // EOF or error before the newline: parse what arrived.
            response.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    }

    /// Connect, write one command, close. No reply expected (telemetry reports).
    @discardableResult
    public func sendFireAndForget(_ command: [String: Any]) -> Bool {
        guard let fd = openConnection(command, halfCloseWrite: true) else { return false }
        close(fd)
        return true
    }

    /// Outcome of `waitForLine`: the first line the predicate accepted, the
    /// server hanging up first, or the deadline passing first.
    public enum LineWaitResult {
        case matched(Data)
        case disconnected
        case timedOut
    }

    /// Streams newline-delimited reply lines until `matches` accepts one, the
    /// server hangs up, or `timeoutMS` elapses — the blocking primitive behind
    /// `cortland_wait_event`. The deadline is enforced with a receive timeout
    /// on the socket, so a silent stream can't block past it.
    public func waitForLine(
        _ command: [String: Any],
        timeoutMS: Int,
        matches: (Data) -> Bool
    ) -> LineWaitResult {
        guard let fd = openConnection(command, halfCloseWrite: false) else { return .disconnected }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            var receiveTimeout = timeval(
                tv_sec: Int(remaining),
                tv_usec: Int32((remaining - floor(remaining)) * 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return .disconnected }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
                if errno == EINTR { continue }
                return .disconnected
            }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex...newline])
                pending = pending[pending.index(after: newline)...]
                if matches(line) { return .matched(line) }
            }
        }
    }

    /// Streams newline-delimited reply lines to `onLine` until the server hangs
    /// up. Returns false only if the connection couldn't be established.
    public func stream(_ command: [String: Any], onLine: (Data) -> Void) -> Bool {
        guard let fd = openConnection(command, halfCloseWrite: false) else { return false }
        defer { close(fd) }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                onLine(Data(pending[pending.startIndex...newline]))
                pending = pending[pending.index(after: newline)...]
            }
        }
        return true
    }
}
