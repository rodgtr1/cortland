---
name: cortland-panes
description: Control Cortland terminal panes and orchestrate visible worker agents. Use when running inside Cortland and asked to split work into panes, launch separate Claude/Codex processes, run servers or tests beside the current agent, inspect pane output, or wait for another pane or agent to finish.
---

# Cortland Panes

Use `cortland-ctl` to control the running Cortland instance. Each terminal pane is a real PTY process; workers launched here are separate CLI processes, not internal subagents.

## Preconditions

Check both conditions before controlling panes:

```sh
test "$CORTLAND_ENV" = 1
command -v cortland-ctl
```

If either fails, report that the current process is not running in an automation-enabled Cortland pane. Do not use GUI keyboard automation.

Discover the caller and current layout:

```sh
cortland-ctl pane current
cortland-ctl pane list
```

Use `CORTLAND_PANE_ID` as the initial target. Treat pane IDs as opaque runtime values and use IDs returned by `pane split` for subsequent operations.

## Launch a worker

Split without stealing the user's focus and launch with an argv array:

```sh
cortland-ctl pane split "$CORTLAND_PANE_ID" \
  --direction right \
  --cwd "$PWD" \
  --no-focus \
  --exec claude
```

Read `result.pane.pane_id` from the JSON response. Do not guess a pane ID.

Send an interactive prompt:

```sh
cortland-ctl pane run "$WORKER_PANE" "Review the API error handling and report concrete defects"
```

`pane run` types the text and presses Enter (delivered as a separate keystroke so TUIs don't swallow it as pasted text). After prompting an interactive agent, read the pane to confirm the prompt actually submitted; if it is still sitting in the input box, send `pane send-key "$WORKER_PANE" enter`.

For a noninteractive worker, launch its complete argv atomically:

```sh
cortland-ctl pane split "$CORTLAND_PANE_ID" \
  --direction down --cwd "$PWD" --no-focus \
  --exec claude -p "Run the focused test suite and diagnose failures"
```

When multiple workers may modify overlapping files, isolate each on its own git worktree — shared panes do not isolate filesystem changes. Pass `--worktree <branch>` to create (or reuse) a worktree for that branch and open the new pane in it, instead of setting up the worktree by hand:

```sh
cortland-ctl pane split "$CORTLAND_PANE_ID" \
  --worktree feature/login --no-focus --exec claude
```

The worktree is created in a sibling `<repo>.worktrees/<branch>` directory from the repo containing the source pane. `--worktree` overrides `--cwd`.

## Coordinate panes

Inspect output already produced. Monitoring is state-driven, not a poll: block on a wait (below), then take one bounded read. Never loop on `pane read`.

Prefer `--source visible` for a progress check; it is the screen, so it is bounded and cheap:

```sh
cortland-ctl pane read "$WORKER_PANE" --source visible --lines 60
```

Reach for `--source recent` only when you genuinely need history. It returns the pane's scrollback transcript plus a `cursor` on stderr; pass that cursor back as `--since` so a follow-up read returns just what arrived after it, instead of the whole buffer again:

```sh
cortland-ctl pane read "$WORKER_PANE" --source recent --lines 200
cortland-ctl pane read "$WORKER_PANE" --source recent --since "$CURSOR"
```

For structured command history instead of a raw screen scrape, add `--json`. It
returns recently finished commands in that pane as records — command line, exit
code, duration, and output — which are easier to reason over than ANSI text.
Requires the shell integration (it carries the command line in the OSC 133 marks):

```sh
cortland-ctl pane read "$WORKER_PANE" --json --lines 20
# [ { "command": "swift build", "exit_code": 1, "duration": 12.4, "output": "..." }, ... ]
```

Wait for future output or an agent state:

```sh
cortland-ctl wait output "$WORKER_PANE" "ready" --timeout 30000
cortland-ctl wait agent-status "$WORKER_PANE" done --timeout 600000
```

Wait commands return exit status 1 on timeout. After waiting, always read the pane rather than assuming success.

To supervise several panes at once without polling each, subscribe to the event stream instead. It holds the connection open and emits one JSON object per line as things happen — agent-state transitions, finished commands (OSC 133), and edit-approval decisions:

```sh
cortland-ctl events --follow
# {"type":"agent_state","pane_id":"…","tab_id":"…","state":"ready","at":"…"}
# {"type":"command","pane_id":"…","command":"swift build","exit_code":0,"duration":4.9,"at":"…"}
# {"type":"diff","path":"/repo/src/api.swift","decision":"accepted","at":"…"}
```

Send input without or with Enter:

```sh
cortland-ctl pane send-text "$WORKER_PANE" "additional context"
cortland-ctl pane send-key "$WORKER_PANE" enter
cortland-ctl pane run "$WORKER_PANE" "additional context"
```

Supported named keys include `enter`, `tab`, `esc`, `backspace`, `ctrl-c`, `ctrl-d`, and arrow directions.

## Complete the handoff

Coordination is pull-based: a worker finishes by printing a summary in its own pane and has no channel to notify the orchestrator. It will never "send the result back".

So when the user's request includes acting on the worker's output — review it, verify it, merge it, report on it — dispatching the task is not the end of the job. Do not end the turn after sending the prompt. Block until the worker goes idle, then read its pane and perform the follow-up in the same turn:

```sh
cortland-ctl wait agent-status "$WORKER_PANE" done --timeout 600000
cortland-ctl pane read "$WORKER_PANE" --source recent --lines 200
```

If the wait times out, read the pane to check progress and wait again; end the turn early only if the worker is stuck or waiting on input only the user can provide, and say so explicitly.

## Manage layout

```sh
cortland-ctl pane focus "$WORKER_PANE"
cortland-ctl pane close "$WORKER_PANE"
```

Cortland currently permits four panes per tab. If a split reports the pane limit, reuse an existing terminal pane or ask the user before closing one.

Do not close panes you did not create unless the user explicitly requests it. Do not send input to a pane until its ID and purpose have been verified with `pane list` or the split response.
