#!/usr/bin/env python3
"""Session Recall - Phase 0 prototype scanner.

Scans local Claude Code and Codex CLI session logs and emits a single unified,
searchable list of past agent sessions. Throwaway prototype: prove the index is
useful before any Cortland UI is built.

Standard library only. Session logs are read-only inputs.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CLAUDE_ROOT = os.path.join(HOME, ".claude", "projects")
CODEX_ROOT = os.path.join(HOME, ".codex", "sessions")

# Read at most this many lines per file while hunting for cwd + timestamp +
# first genuine human prompt. Almost always found in the first handful of lines.
MAX_LINES_PER_FILE = 2000

# Prefixes that mark an injected wrapper / system / tooling payload rather than a
# real human prompt. Compared case-sensitively against the collapsed text.
WRAPPER_PREFIXES = (
    "The following is the Codex agent history",
    "Caveat:",
    "[Request interrupted",
    "This session is being continued from a previous",
)


def collapse(text):
    """Collapse all whitespace/newlines to single spaces and strip."""
    if not text:
        return ""
    return " ".join(text.split())


def is_wrapper(text):
    """True if the candidate title text is injected noise, not a human prompt."""
    if not text:
        return True
    if text.startswith("<"):
        return True
    for prefix in WRAPPER_PREFIXES:
        if text.startswith(prefix):
            return True
    return False


def text_from_content(content):
    """Pull human-authored text out of a message `content` field.

    Handles both a bare string and a list of parts. Only text-bearing parts
    (`text` for Claude, `input_text` for Codex) contribute; tool results,
    tool uses, images, etc. are ignored so they never become a title.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        pieces = []
        for part in content:
            if not isinstance(part, dict):
                continue
            ptype = part.get("type")
            if ptype in ("text", "input_text") and isinstance(part.get("text"), str):
                pieces.append(part["text"])
        return "\n".join(pieces)
    return ""


def rel_age(then, now):
    """Compact relative age string, e.g. 2d, 5h, 30m."""
    if then is None:
        return "?"
    secs = (now - then).total_seconds()
    if secs < 0:
        secs = 0
    if secs < 60:
        return "%ds" % int(secs)
    mins = secs / 60
    if mins < 60:
        return "%dm" % int(mins)
    hours = mins / 60
    if hours < 24:
        return "%dh" % int(hours)
    days = hours / 24
    if days < 7:
        return "%dd" % int(days)
    weeks = days / 7
    if weeks < 52:
        return "%dw" % int(weeks)
    return "%dy" % int(days / 365)


def parse_ts(value):
    """Parse an ISO8601 timestamp (accepting a trailing Z) into aware UTC."""
    if not isinstance(value, str) or not value:
        return None
    try:
        v = value.strip()
        if v.endswith("Z"):
            v = v[:-1] + "+00:00"
        dt = datetime.fromisoformat(v)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def iter_lines(path):
    """Yield parsed JSON objects from a jsonl file, skipping bad lines."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= MAX_LINES_PER_FILE:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except (ValueError, TypeError):
                    continue
    except (OSError, IOError):
        return


def file_mtime(path):
    try:
        return datetime.fromtimestamp(os.path.getmtime(path), tz=timezone.utc)
    except (OSError, ValueError):
        return None


def build_row(agent, cwd, session_id, resume_id, timestamp, title, ai_title, path):
    """Assemble a unified row dict shared by both scanners."""
    verb = "claude --resume" if agent == "claude" else "codex resume"
    if cwd:
        resume_cmd = "cd %s && %s %s" % (cwd, verb, resume_id)
    else:
        # cwd unknown (unrecoverable): the user must cd there themselves.
        resume_cmd = "%s %s" % (verb, resume_id)
    return {
        "agent": agent,
        "cwd": cwd,
        "repo": os.path.basename(cwd.rstrip("/")) if cwd else None,
        "session_id": session_id,
        "resume_id": resume_id,
        "timestamp": timestamp,
        "title": (title or "")[:100],
        "ai_title": ai_title,
        "resume_cmd": resume_cmd,
        "log_path": path,
    }


def scan_claude(path):
    """Return a row dict for one Claude session file, or None."""
    session_id = os.path.splitext(os.path.basename(path))[0]
    cwd = None
    timestamp = None
    title = None
    ai_title = None

    for rec in iter_lines(path):
        if not isinstance(rec, dict):
            continue
        rtype = rec.get("type")
        if cwd is None and isinstance(rec.get("cwd"), str):
            cwd = rec["cwd"]
        if timestamp is None:
            timestamp = parse_ts(rec.get("timestamp"))
        # Claude writes its own AI-generated title into an `ai-title` line;
        # prefer it downstream. It may appear after the first user turn, so we
        # can't early-break on cwd/timestamp/title alone.
        if ai_title is None and rtype == "ai-title" and isinstance(rec.get("aiTitle"), str):
            ai_title = collapse(rec["aiTitle"]) or None
        if title is None and rtype == "user":
            msg = rec.get("message")
            if isinstance(msg, dict) and msg.get("role") == "user":
                cand = collapse(text_from_content(msg.get("content")))
                if cand and not is_wrapper(cand):
                    title = cand

    # cwd is authoritative ONLY from the in-record field. The encoded project
    # dir name is lossy (a literal '-' in a path segment is indistinguishable
    # from an encoded '/'), so we never guess from it -- cwd stays unknown.
    if timestamp is None:
        timestamp = file_mtime(path)
    if title is None:
        title = "(no prompt found)"

    return build_row("claude", cwd, session_id, session_id, timestamp, title, ai_title, path)


def scan_codex(path):
    """Return a row dict for one Codex rollout file, or None."""
    cwd = None
    timestamp = None
    title = None
    session_id = None
    rollout_id = None

    for rec in iter_lines(path):
        if not isinstance(rec, dict):
            continue
        rtype = rec.get("type")
        payload = rec.get("payload")

        if rtype == "session_meta" and isinstance(payload, dict):
            if isinstance(payload.get("cwd"), str):
                cwd = payload["cwd"]
            if isinstance(payload.get("session_id"), str):
                session_id = payload["session_id"]
            if isinstance(payload.get("id"), str):
                rollout_id = payload["id"]
            if timestamp is None:
                timestamp = parse_ts(payload.get("timestamp")) or parse_ts(rec.get("timestamp"))

        if timestamp is None:
            timestamp = parse_ts(rec.get("timestamp"))

        # Codex carries the human prompt on TWO channels: response_item/message
        # (content parts) and event_msg/user_message (a plain `message` string).
        # Read both, or real sessions get mislabeled "(no prompt found)".
        if title is None and rtype in ("response_item", "event_msg") and isinstance(payload, dict):
            ptype = payload.get("type")
            cand = ""
            if ptype == "message" and payload.get("role") == "user":
                cand = collapse(text_from_content(payload.get("content")))
            elif ptype == "user_message" and isinstance(payload.get("message"), str):
                cand = collapse(payload["message"])
            if cand and not is_wrapper(cand):
                title = cand

        if cwd is not None and timestamp is not None and title is not None:
            break

    # Resume id: prefer the rollout uuid from session_meta; fall back to the
    # uuid embedded in the filename (rollout-<ts>-<uuid>.jsonl).
    if rollout_id is None:
        stem = os.path.splitext(os.path.basename(path))[0]
        parts = stem.split("-")
        if len(parts) >= 5:
            rollout_id = "-".join(parts[-5:])
        else:
            rollout_id = stem
    if session_id is None:
        session_id = rollout_id
    if timestamp is None:
        timestamp = file_mtime(path)
    if title is None:
        title = "(no prompt found)"

    return build_row("codex", cwd, session_id, rollout_id, timestamp, title, None, path)


def collect_claude():
    rows = []
    if not os.path.isdir(CLAUDE_ROOT):
        return rows
    try:
        dirs = os.listdir(CLAUDE_ROOT)
    except OSError:
        return rows
    for dirname in dirs:
        proj = os.path.join(CLAUDE_ROOT, dirname)
        if not os.path.isdir(proj):
            continue
        try:
            names = os.listdir(proj)
        except OSError:
            continue
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            row = scan_claude(os.path.join(proj, name))
            if row is not None:
                rows.append(row)
    return rows


def collect_codex():
    rows = []
    if not os.path.isdir(CODEX_ROOT):
        return rows
    for dirpath, _dirnames, filenames in os.walk(CODEX_ROOT):
        for name in filenames:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            row = scan_codex(os.path.join(dirpath, name))
            if row is not None:
                rows.append(row)
    return rows


def truncate(text, width):
    text = text or ""
    if len(text) <= width:
        return text
    if width <= 1:
        return text[:width]
    return text[: width - 1] + "…"


def print_table(rows):
    if not rows:
        print("(no sessions found)")
        return
    now = datetime.now(timezone.utc)

    display = []
    for r in rows:
        display.append(
            {
                "agent": r["agent"],
                "repo": truncate(r["repo"], 20),
                "age": rel_age(r["timestamp"], now),
                "sid": (r["resume_id"] or "")[:8],
                "title": truncate(r["title"], 70),
            }
        )

    headers = {"agent": "AGENT", "repo": "REPO", "age": "AGE", "sid": "SESSION", "title": "TITLE"}
    widths = {}
    for key in ("agent", "repo", "age", "sid", "title"):
        widths[key] = max(len(headers[key]), max(len(d[key]) for d in display))

    def fmt(d):
        return "  ".join(
            [
                d["agent"].ljust(widths["agent"]),
                d["repo"].ljust(widths["repo"]),
                d["age"].rjust(widths["age"]),
                d["sid"].ljust(widths["sid"]),
                d["title"].ljust(widths["title"]),
            ]
        ).rstrip()

    print(fmt(headers))
    print("  ".join("-" * widths[k] for k in ("agent", "repo", "age", "sid", "title")))
    for d in display:
        print(fmt(d))


def to_json(rows):
    out = []
    for r in rows:
        ts = r["timestamp"]
        out.append(
            {
                "agent": r["agent"],
                "cwd": r["cwd"],
                "repo": r["repo"],
                "session_id": r["session_id"],
                "resume_id": r["resume_id"],
                "timestamp": ts.isoformat() if ts is not None else None,
                "title": r["title"],
                "ai_title": r["ai_title"],
                "resume_cmd": r["resume_cmd"],
                "log_path": r["log_path"],
            }
        )
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Scan local Claude Code and Codex CLI session logs into a unified list."
    )
    parser.add_argument("--agent", choices=["claude", "codex"], help="filter to one agent")
    parser.add_argument("--repo", help="case-insensitive substring match on repo/cwd")
    parser.add_argument("--search", help="case-insensitive substring match on title OR cwd")
    parser.add_argument("--limit", type=int, help="cap rows (applied after sorting)")
    parser.add_argument("--json", action="store_true", help="machine-readable JSON output")
    args = parser.parse_args(argv)

    rows = []
    if args.agent in (None, "claude"):
        rows.extend(collect_claude())
    if args.agent in (None, "codex"):
        rows.extend(collect_codex())

    if args.repo:
        needle = args.repo.lower()
        rows = [r for r in rows if needle in (r["repo"] or "").lower() or needle in (r["cwd"] or "").lower()]
    if args.search:
        needle = args.search.lower()
        rows = [r for r in rows if needle in (r["title"] or "").lower() or needle in (r["cwd"] or "").lower()]

    # Sort newest first; rows with no timestamp sink to the bottom.
    epoch = datetime.fromtimestamp(0, tz=timezone.utc)
    rows.sort(key=lambda r: r["timestamp"] or epoch, reverse=True)

    if args.limit is not None and args.limit >= 0:
        rows = rows[: args.limit]

    if args.json:
        json.dump(to_json(rows), sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print_table(rows)


if __name__ == "__main__":
    main()
