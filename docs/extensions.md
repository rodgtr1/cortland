# Building Cortland extensions

An extension adds a panel to Cortland's sidebar and commands to its palette. You write it in any language, as one executable in a folder. Cortland runs that executable and draws what it prints.

Extensions are at API version 1. The exact rules for every field are in the [contract reference](../.claude/skills/cortland-extension-builder/CONTRACT.md). This guide covers how to build one.

## How an extension works

An extension is a folder with two things in it:

- `extension.toml`, a manifest that says what the extension is and what it adds
- one executable, usually `bin/run`

Cortland never loads your code into the app. It runs your executable as a separate process, in two ways:

```
bin/run panel                            # what should the panel show?
bin/run action <action-id> [<row-id>]    # the user picked an action
```

Each time, your executable prints one JSON object and exits. For `panel`, the JSON lists sections and rows. For `action`, it says what Cortland should do next, such as opening a terminal tab.

Because it runs as its own process, a crash in your extension cannot take the terminal down with it. It also means the language is up to you: Python, a shell script, Go, or anything else that can print JSON.

## Your first extension

This builds a panel with one row. Double-clicking the row opens a terminal tab.

**1. Create the folder.** Its name is the extension's id. An id has at least two dot-separated parts, in lowercase.

```sh
mkdir -p ~/cortland-extensions/example.hello/bin
cd ~/cortland-extensions/example.hello
```

**2. Write `extension.toml`.**

```toml
api_version = 1
id = "example.hello"
name = "Hello"
version = "0.1.0"
command = "bin/run"

[panel]
title = "Hello"
icon = "hand.wave"
```

**3. Write `bin/run`.**

```sh
#!/bin/sh
case "$1" in
  panel)
    cat <<'JSON'
{
  "sections": [
    {
      "title": "Greetings",
      "rows": [
        {
          "id": "greeting/world",
          "title": "Hello, world",
          "detail": "double-click me",
          "actions": [{ "id": "say", "title": "Say It in a Tab" }]
        }
      ]
    }
  ]
}
JSON
    ;;
  action)
    echo '{ "open_tab": { "command": ["echo", "Hello from my first extension"] } }'
    ;;
  *)
    echo "usage: run panel | run action <action-id> [<row-id>]" >&2
    exit 2
    ;;
esac
```

**4. Make it executable.**

```sh
chmod +x bin/run
```

**5. Check it.** Cortland must be running.

```sh
cortland-ctl extension validate ~/cortland-extensions/example.hello
```

This prints a JSON report. You want `"valid": true` and an empty `warnings` list.

**6. Install it.** Link the folder into Cortland's extensions directory. A link lets you keep editing the original.

```sh
mkdir -p ~/.config/cortland/extensions
ln -s ~/cortland-extensions/example.hello ~/.config/cortland/extensions/example.hello
```

**7. Enable it.** Open Preferences → Extensions and check **Enabled** next to Hello. New extensions always start disabled.

A wave icon appears at the bottom of the sidebar's icon column. Click it to see your row. Double-click the row and a new tab opens and runs `echo 'Hello from my first extension'`.

Edits to `bin/run` take effect the next time Cortland runs it. Edits to `extension.toml` take effect when you reopen Preferences → Extensions or click Reload there.

## What is required and what is optional

Every extension needs the five core fields. Everything else is added only when you want what it gives you.

| Add this | To get this | Which then requires |
|---|---|---|
| `api_version`, `id`, `name`, `version`, `command` | A valid extension that installs and enables | Always required |
| `description` | A line under the name in Preferences | Nothing |
| `[panel]` | A sidebar panel with its own icon | Your executable answers `panel` |
| Actions in the panel output | Things users can do to a row or the panel | Your executable answers `action` |
| `[[palette]]` entries | Commands in the command palette (⇧⌘P) | A `[panel]`, and an action for each entry |
| An icon file | Your own sidebar icon | An `.svg`, `.pdf`, or `.png` in the folder |

## The panel

`bin/run panel` prints the whole panel each time it runs:

```json
{
  "message": "3 widgets, 1 stopped",
  "actions": [{ "id": "new", "title": "New Widget", "icon": "plus" }],
  "sections": [
    {
      "title": "Running",
      "empty": "No running widgets",
      "rows": [
        {
          "id": "widget/alpha",
          "title": "alpha",
          "detail": "us-east · 2h old",
          "icon": "cube",
          "actions": [
            { "id": "open", "title": "Open" },
            { "id": "delete", "title": "Delete", "confirm": "Delete widget alpha? This cannot be undone." }
          ]
        }
      ]
    }
  ]
}
```

- `message` is a line shown above the sections. Use it to explain an expected problem, such as being logged out.
- `sections` group the rows. A section's `empty` text shows when it has no rows.
- A row's `id` must be unique across the panel. Cortland passes it back to you when the user acts on that row, so encode what you need in it. A prefix such as `widget/` lets one panel hold different kinds of row.
- Every `icon` on a row or an action is an [SF Symbol](https://developer.apple.com/sf-symbols/) name.

Cortland runs `panel` when your panel becomes visible, then every `refresh_seconds` (10 by default) while it stays visible. It does not run for a hidden panel.

## Actions

An action is something the user can do. List row actions in a row's `actions`, and panel-wide actions in the top-level `actions`.

- Double-clicking a row runs its first action, so put the most common one first.
- Right-clicking a row lists all of its actions.
- A panel action with an `icon` gets its own button at the top of the panel. Panel actions without one go in a "…" menu.
- An action with `confirm` makes Cortland ask before running it. Use it for anything destructive.
- An action with a `menu` opens a menu instead of running (a dropdown under its top-bar button, or a submenu in a menu). Each item runs its own action id, as a row action when it has a `row`.

```json
{
  "id": "new", "title": "New Widget", "icon": "plus",
  "menu": [
    { "id": "new", "title": "New Widget" },
    { "id": "new-from", "title": "New Widget from Template", "menu": [
      { "id": "launch", "title": "alpha", "row": "template/alpha" }
    ] }
  ]
}
```

An item with its own `menu` is a submenu, up to 3 menus deep. Older Cortland builds ignore `menu` and run the action itself, so give it an id that works on its own. Double-clicking a row whose first action has a menu does nothing. The full rules are in the [contract reference](../.claude/skills/cortland-extension-builder/CONTRACT.md#action-menus).

When the user picks an action, Cortland runs `bin/run action <action-id> <row-id>` (no row id for a panel action). Your executable does whatever work is needed, then prints what Cortland should do next:

| Print this | Cortland does this |
|---|---|
| `{ "open_tab": { "command": ["ssh", "alpha"] } }` | Opens a terminal tab and runs the command in it |
| `{ "open_url": "https://example.com/" }` | Opens the link in the browser (`http` and `https` only) |
| `{ "copy": "some text" }` | Puts the text on the clipboard |
| `{}` | Nothing more |

You can combine them in one object. To report a failure, print one line to stderr and exit non-zero. Cortland shows that line in an alert.

After every action, Cortland refreshes the panel.

## Palette commands

Each `[[palette]]` entry adds a command to the palette, titled `<panel title>: <entry title>`.

```toml
[[palette]]
title = "New Widget"
action = "new"

[[palette]]
title = "Open Widget"
action = "open"
pick = true
```

Without `pick`, the entry runs a panel action. With `pick = true`, it names a row action: Cortland shows a list of the rows that have it, and runs the action on the row the user chooses.

## Rules for a well-behaved extension

Each of these prevents a failure that showed up while building a real extension.

- **`panel` must be fast and read-only.** It runs every few seconds while the panel is open.
- **`panel` must never open a prompt or a login.** Some command-line tools start a login when their session has expired. On a ten-second refresh, that means a browser window opening every ten seconds. Check the session first with a command that cannot prompt, and only list when it proves you are logged in.
- **Expected problems exit 0.** If the tool is missing or you are logged out, print a panel with a `message` that says so. A non-zero exit shows "Extension error", which should mean something is broken.
- **Give every subprocess a timeout, and stdin from `/dev/null`**, so nothing hangs waiting for input.
- **Only offer an action that can work right now.** No actions while logged out, and no "Open URL" on a row that has no URL.
- **Run interactive or slow work in a tab.** Return `open_tab` so the user can see it and respond. Quick work can run inside your executable, which then returns `{}`.
- **`open_tab.command` is a list of arguments, never one shell string.** Cortland quotes each argument for you.
- **Treat names from other tools as untrusted.** Check the row id's prefix, and reject a name that starts with `-` so it cannot be read as a flag.

## Testing

Write your executable so the function that runs external commands can be swapped for a fake. Then test the panel and every action without calling the real tool. This matters most for actions that create or delete things: test those through the fake, never against your real resources.

The template below is built this way and includes tests.

## Start from the template

A complete starter extension, with a Python executable and tests, is in [`.claude/skills/cortland-extension-builder/template/`](../.claude/skills/cortland-extension-builder/template/). Copy it to a folder named for your extension's id, then replace each `TODO`:

```sh
cp -R .claude/skills/cortland-extension-builder/template ~/cortland-extensions/yourname.yourtool
```

It handles `panel` and `action`, gives every subprocess a timeout, checks row ids, and rejects names that start with `-`.

## Build one with an AI agent

Cortland includes a skill, `cortland-extension-builder`, that teaches Claude Code and other agents to build an extension. It follows the same contract and rules as this guide.

The skill loads on its own when your agent runs inside the Cortland repository. To use it from any folder, link it into your agent's skills directory. For Claude Code:

```sh
ln -s /path/to/cortland/.claude/skills/cortland-extension-builder ~/.claude/skills/cortland-extension-builder
```

Then ask for what you want:

```
Build a Cortland extension that lists my Docker containers and lets me open a shell in one.
```

The agent maps your request onto the tool's commands, copies the template, writes the executable and its tests, runs `cortland-ctl extension validate`, and links the result into the extensions folder. It leaves enabling the extension to you. To share it, put the folder in its own git repository; others install it from the URL.

## Publishing an extension

Each extension lives in its own git repository, with `extension.toml` at the repository root. Anyone who can clone the repository can install the extension from its URL.

The repository's folder name does not matter. Cortland names the install folder from the manifest's `id`, so a repository called `cortland-hello` installs as `example.hello`.

Tag versions however you like. Cortland does not compare versions: Update pulls the latest commit of the branch the repository was cloned from.

## Install, enable, update, disable, uninstall

- **Install from a URL.** In Preferences → Extensions, click **Install from URL…** and enter the repository's URL, or run `cortland-ctl extension install <url>`. Any location git accepts works: `https://`, `ssh://`, `git@host:owner/repo.git`, `file://`, or an absolute local path. Cortland clones the repository, checks its manifest, and puts it at `~/.config/cortland/extensions/<id>`. Installing never runs the extension's command. If something is already at that path, the install fails: update the extension, or remove it first.
- **Install one you are developing.** Link your working folder at `~/.config/cortland/extensions/<id>`, as in step 6 above. Edits take effect without reinstalling.
- **Enable.** Check **Enabled** in Preferences → Extensions. A new extension always starts disabled. The icon and palette commands appear at once.
- **Update.** Click **Update** next to the extension, or run `cortland-ctl extension update <id>`. Cortland runs `git pull --ff-only` in the extension's folder and says whether anything changed. Only an extension installed from a URL has an Update button; Cortland never updates a linked folder. Updating keeps the extension enabled or disabled as it was.
- **Disable.** Uncheck **Enabled**. The icon and palette commands go away, and Cortland stops running the extension.
- **Uninstall.** Click **Remove** in Preferences → Extensions. Cortland moves the folder (or the link) to the Trash.

An SSH URL that needs a passphrase or asks to confirm a host key fails at once instead of waiting for an answer. Load the key into `ssh-agent` or connect to the host once in a terminal, then try again.

An extension whose manifest is invalid is listed in Preferences → Extensions with the reason, and none of it runs. That includes one whose manifest stopped validating after an update.

An extension is a program that runs as you, with your access to your files and accounts. Only install extensions you trust.

## Reference

- [Contract reference](../.claude/skills/cortland-extension-builder/CONTRACT.md): every manifest field, every JSON key, and every validation rule
- [Template](../.claude/skills/cortland-extension-builder/template/): a working extension to copy
- `cortland-ctl extension validate <folder>`: checks a folder against the contract
- `cortland-ctl extension install <url>` and `cortland-ctl extension update <id>`: install and update from a git repository
