import Foundation
import CortlandIPCCore

@main
struct CortlandCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { usageAndExit() }

        let client = CortlandIPCClient()

        // `events` is a long-lived JSONL stream, not a single request/response:
        // connect, then print each line as it arrives until the app hangs up.
        if args.first == "events" {
            var request: [String: Any] = ["action": "events"]
            var index = 1
            while index < args.count {
                switch args[index] {
                case "--follow":
                    break  // streaming is implicit; accepted for readability
                case "--pane":
                    index += 1
                    guard index < args.count else { fail("--pane requires a pane id") }
                    request["pane_id"] = args[index]
                case "--type":
                    index += 1
                    guard index < args.count else { fail("--type requires an event type") }
                    request["type"] = args[index]
                default:
                    fail("Unknown events option: \(args[index])")
                }
                index += 1
            }
            let stdout = FileHandle.standardOutput
            guard client.stream(request, onLine: { stdout.write($0) }) else {
                fail("Cortland is not responding")
            }
            return
        }

        // `wait event` consumes the event stream until the first match rather
        // than making a single request/response — handled on the streaming path.
        if args.prefix(2).elementsEqual(["wait", "event"]) {
            runWaitEvent(Array(args.dropFirst(2)), client: client)
            return
        }

        do {
            let request = try makeRequest(args)
            guard let response = client.send(request) else {
                fail("Cortland is not responding")
            }
            guard response["ok"] as? Bool == true else {
                fail(response["error"] as? String ?? "Cortland rejected the request")
            }

            if args.first == "ping" {
                print("Cortland is running")
            } else if args.prefix(2).elementsEqual(["pane", "read"]),
                      let result = response["result"] as? [String: Any] {
                if let commands = result["commands"] {
                    // `pane read --json`: emit the structured command records.
                    printJSON(commands)
                } else if let text = result["text"] as? String {
                    print(text)
                    // Keep stdout the pane text; surface the delta-read cursor and
                    // any re-sync as stderr diagnostics a poller can capture apart.
                    if (result["truncated"] as? Bool) == true {
                        warn("truncated: cursor was stale or evicted; text is a full re-read")
                    }
                    if let cursor = result["cursor"] as? String {
                        warn("cursor: \(cursor)")
                    }
                }
            } else if shouldPrintJSON(args) {
                printJSON(response)
            } else if args.prefix(2).elementsEqual(["wait", "agent-status"])
                        || args.prefix(2).elementsEqual(["wait", "output"]) {
                let matched = (response["result"] as? [String: Any])?["matched"] as? Bool ?? false
                if !matched { exit(1) }
            } else if args.first == "agent-list" {
                printJSON((response["result"] as? [String: Any])?["agents"] ?? [])
            } else if args.prefix(2).elementsEqual(["worktree", "list"]) {
                printJSON((response["result"] as? [String: Any])?["worktrees"] ?? [])
            } else if args.prefix(2).elementsEqual(["worktree", "prune"]) {
                if let text = (response["result"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                    print(text)
                }
            }
        } catch let error as CLIError {
            fail(error.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Expands a leading ~ before the path reaches server-side validation,
    /// which only accepts absolute paths — a quoted `'~/proj'` would otherwise
    /// fail with a misleading error.
    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func makeRequest(_ args: [String]) throws -> [String: Any] {
        switch args[0] {
        case "ping":
            return ["action": "ping"]
        case "new-tab":
            let cwd = args.count > 1 ? expandTilde(args[1]) : FileManager.default.currentDirectoryPath
            return ["action": "new_tab", "cwd": cwd]
        case "open-diff":
            guard args.count == 2 else { throw CLIError("open-diff requires a file path") }
            return ["action": "show_diff", "path": expandTilde(args[1]), "old": "", "new": ""]
        case "agent-list": return ["action": "agent_list"]
        case "agent-ready": return ["action": "agent_ready"]
        case "agent-busy": return ["action": "agent_busy"]
        case "agent-done": return ["action": "agent_done"]
        case "agent-idle": return ["action": "agent_idle"]
        case "pane":
            return try paneRequest(Array(args.dropFirst()))
        case "wait":
            return try waitRequest(Array(args.dropFirst()))
        case "worktree":
            return try worktreeRequest(Array(args.dropFirst()))
        default:
            throw CLIError("Unknown command: \(args[0])")
        }
    }

    private static func worktreeRequest(_ args: [String]) throws -> [String: Any] {
        guard let subcommand = args.first else {
            throw CLIError("worktree requires a subcommand: list | remove <branch> | prune")
        }
        switch subcommand {
        case "list":
            var request: [String: Any] = ["action": "worktree_list"]
            var index = 1
            while index < args.count {
                switch args[index] {
                case "--cwd":
                    index += 1
                    guard index < args.count else { throw CLIError("--cwd requires a directory") }
                    request["cwd"] = expandTilde(args[index])
                default:
                    throw CLIError("Unknown worktree list option: \(args[index])")
                }
                index += 1
            }
            return request
        case "remove":
            guard args.count >= 2 else { throw CLIError("worktree remove requires a branch name") }
            var request: [String: Any] = ["action": "worktree_remove", "worktree": args[1]]
            var index = 2
            while index < args.count {
                switch args[index] {
                case "--cwd":
                    index += 1
                    guard index < args.count else { throw CLIError("--cwd requires a directory") }
                    request["cwd"] = expandTilde(args[index])
                case "--force":
                    request["force"] = true
                default:
                    throw CLIError("Unknown worktree remove option: \(args[index])")
                }
                index += 1
            }
            return request
        case "prune":
            var request: [String: Any] = ["action": "worktree_prune"]
            var index = 1
            while index < args.count {
                switch args[index] {
                case "--cwd":
                    index += 1
                    guard index < args.count else { throw CLIError("--cwd requires a directory") }
                    request["cwd"] = expandTilde(args[index])
                default:
                    throw CLIError("Unknown worktree prune option: \(args[index])")
                }
                index += 1
            }
            return request
        default:
            throw CLIError("Unknown worktree subcommand: \(subcommand)")
        }
    }

    private static func paneRequest(_ args: [String]) throws -> [String: Any] {
        guard let subcommand = args.first else { throw CLIError("pane requires a subcommand") }
        switch subcommand {
        case "list":
            return ["action": "pane_list"]
        case "current":
            var request: [String: Any] = ["action": "pane_current"]
            if let paneID = ProcessInfo.processInfo.environment["CORTLAND_PANE_ID"] {
                request["pane_id"] = paneID
            }
            return request
        case "split":
            guard args.count >= 2 else { throw CLIError("pane split requires a pane ID") }
            var request: [String: Any] = [
                "action": "pane_split",
                "pane_id": args[1],
                "direction": "right",
                "focus": true,
            ]
            var index = 2
            while index < args.count {
                switch args[index] {
                case "--direction":
                    index += 1
                    guard index < args.count else { throw CLIError("--direction requires right or down") }
                    request["direction"] = args[index]
                case "--cwd":
                    index += 1
                    guard index < args.count else { throw CLIError("--cwd requires a directory") }
                    request["cwd"] = expandTilde(args[index])
                case "--worktree":
                    index += 1
                    guard index < args.count else { throw CLIError("--worktree requires a branch name") }
                    request["worktree"] = args[index]
                case "--no-focus":
                    request["focus"] = false
                case "--exec":
                    let command = Array(args.dropFirst(index + 1))
                    guard !command.isEmpty else { throw CLIError("--exec requires a command") }
                    request["command"] = command
                    index = args.count
                    continue
                default:
                    throw CLIError("Unknown pane split option: \(args[index])")
                }
                index += 1
            }
            return request
        case "focus", "close":
            guard args.count == 2 else { throw CLIError("pane \(subcommand) requires a pane ID") }
            return ["action": "pane_\(subcommand)", "pane_id": args[1]]
        case "send-text":
            guard args.count >= 3 else { throw CLIError("pane send-text requires a pane ID and text") }
            return ["action": "pane_send_text", "pane_id": args[1], "text": args.dropFirst(2).joined(separator: " ")]
        case "send-key":
            guard args.count == 3 else { throw CLIError("pane send-key requires a pane ID and key") }
            return ["action": "pane_send_key", "pane_id": args[1], "key": args[2]]
        case "run":
            guard args.count >= 3 else { throw CLIError("pane run requires a pane ID and command text") }
            return ["action": "pane_run", "pane_id": args[1], "text": args.dropFirst(2).joined(separator: " ")]
        case "read":
            guard args.count >= 2 else { throw CLIError("pane read requires a pane ID") }
            var request: [String: Any] = ["action": "pane_read", "pane_id": args[1], "source": "visible"]
            var index = 2
            while index < args.count {
                switch args[index] {
                case "--source":
                    index += 1
                    guard index < args.count else { throw CLIError("--source requires visible or recent") }
                    request["source"] = args[index]
                case "--lines":
                    index += 1
                    guard index < args.count, let lines = Int(args[index]) else { throw CLIError("--lines requires an integer") }
                    request["lines"] = lines
                case "--since":
                    index += 1
                    guard index < args.count else { throw CLIError("--since requires a cursor") }
                    request["since"] = args[index]
                case "--json":
                    request["format"] = "json"
                default:
                    throw CLIError("Unknown pane read option: \(args[index])")
                }
                index += 1
            }
            return request
        default:
            throw CLIError("Unknown pane subcommand: \(subcommand)")
        }
    }

    private static func waitRequest(_ args: [String]) throws -> [String: Any] {
        guard args.count >= 3 else { throw CLIError("wait requires agent-status/output, a pane ID, and a value") }
        var request: [String: Any] = ["pane_id": args[1], "timeout_ms": 30_000]
        switch args[0] {
        case "agent-status":
            request["action"] = "wait_agent_status"
            request["status"] = args[2]
        case "output":
            request["action"] = "wait_output"
            request["match"] = args[2]
        default:
            throw CLIError("Unknown wait target: \(args[0])")
        }
        var index = 3
        while index < args.count {
            guard args[index] == "--timeout", index + 1 < args.count, let timeout = Int(args[index + 1]) else {
                throw CLIError("wait supports only --timeout <milliseconds>")
            }
            request["timeout_ms"] = timeout
            index += 2
        }
        return request
    }

    /// `wait event`: blocks until the next event (optionally narrowed by pane
    /// and type) and prints it as one JSON line — the CLI twin of the MCP
    /// cortland_wait_event tool. Subscribes without the backlog replay, so only
    /// events emitted after the call starts can satisfy the wait. Exits 1 on
    /// timeout, matching the other `wait` verbs.
    private static func runWaitEvent(_ options: [String], client: CortlandIPCClient) {
        var request: [String: Any] = ["action": "events", "backlog": false]
        var timeoutMS = 30_000
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--pane":
                index += 1
                guard index < options.count else { fail("--pane requires a pane id") }
                request["pane_id"] = options[index]
            case "--type":
                index += 1
                guard index < options.count else { fail("--type requires an event type") }
                request["type"] = options[index]
            case "--timeout":
                index += 1
                guard index < options.count, let timeout = Int(options[index]) else {
                    fail("--timeout requires milliseconds")
                }
                timeoutMS = timeout
            default:
                fail("Unknown wait event option: \(options[index])")
            }
            index += 1
        }

        var matched: Data?
        let outcome = client.waitForLine(request, timeoutMS: timeoutMS) { line in
            // The hello connection marker always arrives first; everything
            // after it is a live event the server already filtered.
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (event["type"] as? String) != "hello" else { return false }
            matched = line
            return true
        }
        switch outcome {
        case .matched:
            if let matched { FileHandle.standardOutput.write(matched) }
        case .timedOut:
            exit(1)
        case .disconnected:
            fail("Cortland is not responding")
        }
    }

    private static func shouldPrintJSON(_ args: [String]) -> Bool {
        args.first == "pane" && args.count > 1 && ["list", "current", "split", "focus"].contains(args[1])
    }

    private static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return }
        print(string)
    }

    private static func usageAndExit() -> Never {
        print("""
        Usage: cortland-ctl <command>
          ping | new-tab [cwd] | open-diff <file>
          agent-ready | agent-busy | agent-done | agent-idle
          agent-list                                       fleet status for every agent pane as JSON
          pane list | current
          pane split <pane-id> [--direction right|down] [--cwd dir] [--worktree branch] [--no-focus] [--exec command args...]
          pane focus|close <pane-id>
          pane send-text <pane-id> <text> | send-key <pane-id> <key> | run <pane-id> <command>
          pane read <pane-id> [--source visible|recent] [--lines count] [--since cursor] [--json]
                              wait first, then read once; never poll in a loop.
                              --source visible (default) is the screen: use it to check
                              progress. --source recent is the scrollback transcript
                              --since returns only recent output after a prior read's
                              cursor (printed to stderr); re-reads in full on a stale one
          wait agent-status <pane-id> <idle|working|ready|done> [--timeout ms]
          wait output <pane-id> <text> [--timeout ms]
          wait event [--pane id] [--type agent_state|command|diff|telemetry] [--timeout ms]
                              block until the next matching event and print it as JSON;
                              exits 1 on timeout. Current state is not replayed.
          worktree list [--cwd dir]                        list worktrees as JSON (branch, path, head)
          worktree remove <branch> [--cwd dir] [--force]   tear down a --worktree split
          worktree prune [--cwd dir]                       drop stale worktree entries
          events [--follow] [--pane id] [--type agent_state|command|diff]
                              stream events as JSONL; replays current pane state on connect
        """)
        exit(1)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    /// Non-fatal diagnostic on stderr, so stdout stays the pane's text.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

