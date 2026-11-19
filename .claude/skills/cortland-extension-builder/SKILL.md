---
name: cortland-extension-builder
description: Cortland extension builder. Use when asked to build a Cortland extension (a sidebar panel and palette commands) for a CLI or service, or to change or debug an existing Cortland extension.
---

# Cortland extension builder

A Cortland extension is a folder with an `extension.toml` and one executable, `bin/run`. Cortland runs `bin/run panel` to fill a sidebar panel and `bin/run action <action-id> [<row-id>]` when the user picks an action. Every field, JSON key, and UI behavior is in [CONTRACT.md](CONTRACT.md): read it before writing any manifest or JSON, and check every key you emit against it.

The starting point is this skill's [`template/`](template/), a working extension with the id `example.widgets`. Its `TODO` comments mark every place to replace.

## Branches

- **New extension**: run every step in order.
- **Change or debug an existing one**: run step 5 on its folder first and read what it reports, then read its `bin/run` and tests. Make the change through steps 3 to 7. For a panel that shows "Extension error", run `bin/run panel` yourself from the extension folder and read stdout, stderr, and the exit status.

## Steps

1. **Map the extension onto the CLI.** List the sections and what one row stands for in each, the detail each row shows, every action, and the exact CLI command behind each row source and each action. Run each read-only command and save its real output. Never guess a JSON field name: when a shape cannot be observed (an empty list, a state you cannot reach), say so in a code comment beside the code that reads it, and tell the user.
   Done when: every row field and every action maps to a CLI command, and every field name the code will read either appears in captured output or is marked unverified.

2. **Create the folder.** Copy `template/` to a new folder outside the Cortland repo, at a path the user chooses (ask if they did not say). Name the folder exactly the extension's id, and set `id` to match.
   Done when: `<folder>/extension.toml` has the new id, and the folder name equals it.

3. **Implement `panel`, then `action`.** Replace every `TODO` in `extension.toml` and `bin/run`. Follow the rules below.
   Done when: no `TODO` remains, and `bin/run panel` prints valid panel JSON both with and without a live session.

4. **Test with a fake runner.** Extend `tests/test_run.py`: every row source, the logged-out and tool-missing panels, every action, and every rejection of a bad row id. Tests never call the real CLI. Run them with `/usr/bin/python3 -m unittest discover -s <folder>/tests -v`, then delete any `__pycache__` folders.
   Done when: every action has a test and the run reports OK.

5. **Validate.** Run `cortland-ctl extension validate <folder>` and fix every error and every warning. Palette warnings mean nothing while the panel is logged out; validate with a live session. If the running Cortland answers `Unknown command: extension_validate`, it is too old: say so in the report and do not install.
   Done when: `valid` is true and `warnings` is empty.

6. **Install.** `mkdir -p ~/.config/cortland/extensions && ln -s <folder> ~/.config/cortland/extensions/<id>`. Then tell the user to open Preferences → Extensions and check **Enabled**. Do not enable it yourself and never write `~/.config/cortland/extensions.json`: whether an extension runs is the user's decision.
   To share the extension, the user puts the folder in its own git repository; others install it from the URL with **Install from URL…** in Preferences → Extensions or `cortland-ctl extension install <url>`.
   Done when: the symlink exists and the user has been told how to enable it.

7. **Report.** State what you ran and what it printed: the tests, the validator, and `bin/run panel` against the real CLI. Name every action verified only through the fake runner, and every field name marked unverified in step 1.
   Done when: every action appears in the report as verified for real or verified only through the fake.

## Rules

- **`panel` is fast, read-only, and never prompts.** It runs every `refresh_seconds` while the panel is visible. If the CLI can open a login flow when its session has expired, first check session state with a command that cannot prompt, and list only on positive proof of a live session. Anything else counts as logged out (fail closed). A login window popping up every 10 seconds is the failure this prevents.
- **Expected problems exit 0.** Tool not installed, logged out, timed out: `panel` exits 0 and explains it in `message`. A non-zero exit shows "Extension error", which is for real failures.
- **Every subprocess gets a timeout and stdin from `/dev/null`**, so nothing hangs waiting for input that will never come. The template's `run_command` does both.
- **Emit an action only when it can work right now.** No actions while logged out; no "Open URL" on a row that has no URL.
- **Interactive or long-running actions return `open_tab`**, so they run in a terminal the user can see and answer. A quick headless action runs inside `bin/run` and returns `{}`. Anything destructive carries `confirm`.
- **`open_tab.command` is an argv array.** Never build a shell string: Cortland quotes each element.
- **Ids and names from the external tool are untrusted.** Check the row id prefix, and reject a value that starts with `-` so the CLI cannot read it as a flag. The template's `row_value` does both.
- **Never touch the user's real resources while developing.** Do not run a real command that creates, changes, or deletes anything. Verify those paths with the fake runner and say so in the report.
