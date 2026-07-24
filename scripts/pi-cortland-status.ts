// Cortland agent-status extension for the Pi coding agent.
//
// Reports Pi's lifecycle to Cortland's agents panel using the same OSC 666
// termprop sequence that cortland-agent-status emits for Claude Code/Codex
// hooks, and routes Pi's file-edit tools through Cortland's diff-approval desk.
// Installed to ~/.pi/agent/extensions/ by install-agent-status-hooks.
//
// Mapping:
//   session_start            -> done   (registers the tab in the agents panel on open)
//   agent_start              -> busy   (working on a prompt)
//   tool_call                -> busy   (resets from ready once tools start running)
//   project_trust            -> ready  (Pi needs user to approve project trust)
//   agent_end                -> done   (back at the input prompt)
//   session_shutdown(quit)   -> idle   (removed from the agents panel)
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { closeSync, openSync, readFileSync, writeSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const TERMPROP = "vte.ext.cortland.agent";

function report(status: "busy" | "ready" | "done" | "idle"): void {
  try {
    const fd = openSync("/dev/tty", "w");
    try {
      writeSync(fd, `\x1b]666;${TERMPROP}=${status}\x1b\\`);
    } finally {
      closeSync(fd);
    }
  } catch {
    // No controlling terminal (print/RPC mode) — nothing to report to.
  }
}

// --- Cortland edit-gate ------------------------------------------------------
// Route Pi's file-edit tools through Cortland's diff-approval desk: reconstruct
// the old/new file bodies, send a blocking `show_diff` over the same Unix socket
// the cortland-agent-status hook uses, and allow or deny the tool call on the
// reviewer's verdict — so the desk's prompt replaces Pi's rather than adding a
// second one. Fail-open by contract: no socket, an oversized or binary body, or
// any error lets the tool proceed to Pi's own flow. Never throws into Pi.
const CORTLAND_MAX_DIFF_BYTES = 4 * 1024 * 1024;

function cortlandSocketPath(): string {
  const override = process.env.CORTLAND_SOCKET_PATH;
  if (override && override.length > 0) return override;
  return join(homedir(), ".config", "cortland", "cortland.sock");
}

// Current file body for review: a string to diff, undefined for a missing file
// (a new-file write), or null for a body we must not diff — binary or over the
// IPC ceiling — which the caller treats as fail-open.
function cortlandReviewableBody(filePath: string): string | null | undefined {
  let buf: Buffer;
  try {
    buf = readFileSync(filePath);
  } catch {
    return undefined;
  }
  if (buf.length > CORTLAND_MAX_DIFF_BYTES || buf.includes(0)) return null;
  const text = buf.toString("utf8");
  // Reject invalid UTF-8 (re-encoding wouldn't round-trip) as binary.
  if (!Buffer.from(text, "utf8").equals(buf)) return null;
  return text;
}

interface CortlandEdit {
  oldText: string;
  newText: string;
}

function cortlandNormalizeEdits(input: unknown): CortlandEdit[] | undefined {
  const obj = input as { edits?: unknown; oldText?: unknown; newText?: unknown };
  if (obj && Array.isArray(obj.edits)) return obj.edits as CortlandEdit[];
  if (obj && typeof obj.oldText === "string" && typeof obj.newText === "string") {
    return [{ oldText: obj.oldText, newText: obj.newText }];
  }
  return undefined;
}

// Apply edits Pi-style: every oldText matched against the ORIGINAL body,
// non-overlapping. Returns undefined when an edit can't be resolved so the gate
// falls open rather than reviewing a diff Pi wouldn't produce.
function cortlandApplyEdits(original: string, edits: CortlandEdit[]): string | undefined {
  const spans: { start: number; end: number; newText: string }[] = [];
  for (const edit of edits) {
    if (
      !edit || typeof edit.oldText !== "string" || typeof edit.newText !== "string"
      || edit.oldText.length === 0
    ) {
      return undefined;
    }
    const start = original.indexOf(edit.oldText);
    if (start < 0) return undefined;
    spans.push({ start, end: start + edit.oldText.length, newText: edit.newText });
  }
  spans.sort((a, b) => a.start - b.start);
  for (let i = 1; i < spans.length; i++) {
    if (spans[i].start < spans[i - 1].end) return undefined; // overlapping: fall open
  }
  let result = "";
  let cursor = 0;
  for (const span of spans) {
    result += original.slice(cursor, span.start) + span.newText;
    cursor = span.end;
  }
  return result + original.slice(cursor);
}

// Blocking round-trip to the desk. Resolves true (approved), false (rejected),
// or undefined (unreachable / malformed / timed out) => fail-open. The 600s
// ceiling mirrors the Claude edit-gate hook's own timeout.
function cortlandRequestDiff(
  filePath: string,
  oldBody: string,
  newBody: string,
): Promise<boolean | undefined> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (verdict: boolean | undefined): void => {
      if (settled) return;
      settled = true;
      resolve(verdict);
    };

    const command: Record<string, unknown> = {
      action: "show_diff",
      path: filePath,
      old: oldBody,
      new: newBody,
    };
    const paneID = process.env.CORTLAND_PANE_ID;
    if (paneID) command.pane_id = paneID;

    let buffer = "";
    const resolveLine = (line: string): void => {
      try {
        const response = JSON.parse(line);
        if (response && response.ok === true && typeof response.accepted === "boolean") {
          finish(response.accepted);
          return;
        }
      } catch {
        // fall through to fail-open
      }
      finish(undefined);
    };

    const socket = connect(cortlandSocketPath());
    socket.setEncoding("utf8");
    socket.setTimeout(600_000);
    socket.on("connect", () => {
      // One newline-framed JSON line, then half-close so the server replies.
      socket.end(`${JSON.stringify(command)}\n`);
    });
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline >= 0) {
        resolveLine(buffer.slice(0, newline));
        socket.destroy();
      }
    });
    socket.on("end", () => resolveLine(buffer)); // EOF before newline: parse what arrived
    socket.on("timeout", () => {
      finish(undefined);
      socket.destroy();
    });
    socket.on("error", () => finish(undefined));
    socket.on("close", () => finish(undefined));
  });
}

// Gate `edit` and `write` on the desk's verdict; every other tool passes through.
async function cortlandGateEdit(
  event: { toolName: string; input: unknown },
): Promise<{ block: boolean; reason: string } | undefined> {
  try {
    if (event.toolName !== "edit" && event.toolName !== "write") return undefined;
    const input = event.input as { path?: unknown; content?: unknown };
    const filePath = input?.path;
    if (typeof filePath !== "string" || filePath.length === 0) return undefined;

    const current = cortlandReviewableBody(filePath);
    if (current === null) return undefined; // binary / oversized: fall open

    let oldBody: string;
    let newBody: string;
    if (event.toolName === "write") {
      if (typeof input.content !== "string") return undefined;
      oldBody = current ?? "";
      newBody = input.content;
    } else {
      if (current === undefined) return undefined; // editing a missing file: let Pi report it
      const edits = cortlandNormalizeEdits(event.input);
      if (!edits) return undefined;
      const applied = cortlandApplyEdits(current, edits);
      if (applied === undefined) return undefined;
      oldBody = current;
      newBody = applied;
    }

    if (oldBody === newBody) return undefined; // no-op
    if (Buffer.byteLength(newBody, "utf8") > CORTLAND_MAX_DIFF_BYTES) return undefined;

    const verdict = await cortlandRequestDiff(filePath, oldBody, newBody);
    if (verdict === false) {
      return {
        block: true,
        reason: `The user rejected this edit to ${basename(filePath)} in Cortland's review `
          + "panel. Ask the user how to proceed instead of retrying the same edit.",
      };
    }
    return undefined; // approved, or desk unreachable: let the tool run, no second prompt
  } catch {
    return undefined; // never break the agent
  }
}
// ----------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
  // Register the tab in the agents panel as soon as the session opens.
  pi.on("session_start", async () => report("done"));

  pi.on("agent_start", async () => report("busy"));

  // Flip back to busy as soon as a tool starts executing — covers the case
  // where a project_trust dialog was just resolved and the pending tool runs.
  pi.on("tool_call", async () => report("busy"));

  // Carry file edits to Cortland's approval desk and block on the verdict.
  pi.on("tool_call", async (event) => cortlandGateEdit(event));

  // Pi needs the user to approve running code in this directory.
  // Report ready so Cortland highlights it, then return undecided so Pi
  // handles the actual trust UI itself.
  pi.on("project_trust", async () => {
    report("ready");
    return { trusted: "undecided" as const };
  });

  pi.on("agent_end", async () => report("done"));

  pi.on("session_shutdown", async (event) => {
    if (event.reason === "quit") {
      report("idle");
    }
  });
}
