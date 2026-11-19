# Cortland extension contract

The complete reference for what Cortland expects of an extension and what it does with one. The example throughout is `acme.widgets`, an extension that lists widgets from an `acme` CLI.

## Folder

An extension is one folder:

```
acme.widgets/
  extension.toml
  bin/run          (executable)
  icon.svg         (optional, when panel.icon names a file)
  tests/           (yours; Cortland ignores it)
```

Cortland looks in `~/.config/cortland/extensions/`. Every visible folder there is an extension, and a symlink to a folder counts. Hidden entries and plain files are skipped.

The folder's name must equal the manifest's `id`. A folder whose manifest does not validate is listed in Preferences → Extensions with its error, and nothing of it runs.

## `extension.toml`

TOML. Unknown keys are ignored.

| Key | Required | Rule |
|---|---|---|
| `api_version` | yes | Integer, at least 1 and at most the API version Cortland supports (1). |
| `id` | yes | Two or more dot-separated segments. Each segment is lowercase letters, digits, and single hyphens, not starting or ending with a hyphen (`acme.widgets`, `acme.widget-stats`). Must equal the folder name. |
| `name` | yes | Non-empty string. Shown in Preferences → Extensions. |
| `version` | yes | Non-empty string. Free-form, not parsed as semver. |
| `description` | no | String. Shown under the name in Preferences → Extensions. |
| `command` | yes | Path relative to the folder: not absolute, and it must stay inside the folder both as written (`..`) and after resolving symlinks. Must exist, be a file, and be executable. |

### `[panel]` (optional)

Adds a sidebar panel filled by `<command> panel`.

| Key | Required | Rule |
|---|---|---|
| `title` | yes | Non-empty string. The sidebar's title (shown uppercased), the activity bar tooltip, and the prefix of palette entries. |
| `icon` | yes | Non-empty string. Ending in `.svg`, `.pdf`, or `.png` (any case), it is an image file inside the folder: it must exist, must not be a directory, must stay inside the folder (also after resolving symlinks), and is drawn as a template image tinted like the built-in icons, scaled to fit 24 points. Anything else is an SF Symbol name; one that does not exist shows a generic puzzle-piece symbol instead. |
| `refresh_seconds` | no | Integer, at least 2. Default 10. |

### `[[palette]]` (optional, repeatable)

Each entry adds a command palette command. Entries need a `[panel]`.

| Key | Required | Rule |
|---|---|---|
| `title` | yes | Non-empty string. Listed as `<panel title>: <title>`, for example `Widgets: New Widget`. |
| `action` | yes | Non-empty string: the id of an action in the panel output. |
| `pick` | no | Boolean, default false. False: `action` is a panel action. True: `action` is a row action, and the user picks a row first. |

No two entries may share both `action` and `pick`.

## Running the command

Cortland runs the command in two forms:

```
<command> panel
<command> action <action-id>            # a panel action
<command> action <action-id> <row-id>   # a row action
```

- The executable is `command` resolved to its real path inside the folder.
- The working directory is the extension folder.
- The environment is Cortland's own, with `PATH` replaced by the user's login shell `PATH` (asked once per app launch; the app's own `PATH` if that fails), and `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS=/usr/bin/true` set.
- Cortland sends the command no input.
- Cortland stops a command that runs past 120 seconds (SIGTERM, then SIGKILL 2 seconds later).
- stdout must be one JSON object. stderr is read only when the exit status is non-zero.
- A non-zero exit is a failure. Its reason is the first non-empty stderr line (trimmed), or `exited with status N` when stderr is empty. A command that cannot be started fails with `could not run the command: <detail>`.

A failed or invalid `panel` run shows **Extension error** in red in the panel, with the reason under it. A failed or invalid `action` run shows an alert titled with the action's title, with the reason as its text.

## Panel output

What `<command> panel` prints:

```json
{
  "message": "3 widgets, 1 stopped",
  "actions": [
    { "id": "new", "title": "New Widget", "icon": "plus" }
  ],
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

| Key | Where | Required | Meaning |
|---|---|---|---|
| `message` | top level | no | String shown above the sections when non-empty. |
| `sections` | top level | no | Array of sections, default empty. |
| `actions` | top level | no | Array of panel actions, default empty. |
| `title` | section | yes | String, shown uppercased as the section header. |
| `empty` | section | no | String shown when the section has no rows. |
| `rows` | section | no | Array of rows, default empty. |
| `id` | row | yes | Non-empty string, unique across the whole panel. Passed back as `<row-id>`. |
| `title` | row | yes | String. |
| `detail` | row | no | String shown after the title in smaller text, in the tooltip, and as the second line in the palette's row picker. |
| `icon` | row | no | SF Symbol name drawn before the title. An unknown name draws no icon. |
| `actions` | row | no | Array of row actions, default empty. |
| `id` | action | yes | Non-empty string, unique within its list. Passed back as `<action-id>`. |
| `title` | action | yes | Non-empty string. The menu item, button tooltip, and confirm button text. |
| `confirm` | action | no | String. When present, Cortland asks first in an alert with this text, a button titled with the action's title, and Cancel. |
| `icon` | action | no | SF Symbol name. Used only on panel actions; ignored on row actions. |
| `menu` | action | no | Non-empty array of menu items. Choosing the action in the panel opens this menu instead of running the action. See "Action menus". |

Unknown keys are ignored at every level. A wrong type, a missing required key, an empty id or action title, a duplicate row id, a duplicate action id within one list, or a broken `menu` rule (see "Action menus") makes the whole output invalid, and the panel shows the error instead.

## Action menus

A panel action or a row action may carry a `menu`. Choosing that action in the panel opens the menu; the user then picks an item, and the item runs.

```json
{
  "actions": [
    {
      "id": "new",
      "title": "New Widget",
      "icon": "plus",
      "menu": [
        { "id": "new", "title": "New Widget" },
        {
          "id": "new-from",
          "title": "New Widget from Template",
          "menu": [
            { "id": "launch", "title": "alpha", "row": "template/alpha" },
            { "id": "launch", "title": "beta", "row": "template/beta" }
          ]
        }
      ]
    }
  ]
}
```

| Key | Required | Meaning |
|---|---|---|
| `title` | yes | Non-empty string. The menu item's text, the confirm button text, and the failure alert's title. |
| `id` | yes | Non-empty string. For an item that runs, the `<action-id>` passed to `<command> action`. |
| `confirm` | no | String. As on actions: Cortland asks first, and Cancel runs nothing. |
| `row` | no | String. When non-empty, the item runs as a row action with this row id: `<command> action <id> <row>`. When absent or empty, it runs as a panel action: `<command> action <id>`. The row id need not be a row the panel shows. |
| `menu` | no | Non-empty array of menu items, shown as a submenu. An item with a `menu` does not run. |

Rules (any violation makes the whole output invalid):

- A `menu`, on an action or an item, is never an empty array.
- An item with a `menu` has no `row` and no `confirm`.
- Menus nest at most 3 deep in total: the action's own menu plus two levels of submenu.
- Menu item ids need not be unique. Several items may share an `id` and differ by `row`, as above. The uniqueness rule for action lists is unchanged.
- Unknown keys on a menu item are ignored.

A leaf item runs exactly as an action does: `confirm`, the failure alert, the result's effects, one action at a time, and the refresh afterwards.

**Older Cortland builds** do not know `menu`. They ignore it as an unknown key and run the parent action itself. Give the parent an `id` that does something sensible when run directly. In the example, clicking "+" in an older build runs `new`, the same as the menu's first item.

## How rows and actions surface

- **Double-click** a row: runs the row's first action. When that action has a `menu`, double-click does nothing, since a menu cannot open from a double-click.
- **Context menu** on a row: lists all of the row's actions in order. An action with a `menu` is an item with a submenu.
- **Panel actions** whose `icon` is a real SF Symbol get their own button in the panel's top bar, in listed order, left of the Refresh button. Clicking a button whose action has a `menu` shows that menu below the button and runs nothing. The rest are listed in the **Actions** menu (an ellipsis button), which is hidden when there are none; there an action with a `menu` is an item with a submenu.
- Nested menus are submenus.
- **Refresh** button in the top bar runs `panel` now.
- An action with `confirm` asks first; Cancel runs nothing.
- One action runs at a time per extension, shared between the panel and the palette. A request while one is running is ignored.

## Action result

What `<command> action ...` prints on success: one JSON object with any combination of these keys. `{}` means nothing more to do.

| Key | Value | Effect |
|---|---|---|
| `open_tab` | `{ "command": ["acme", "widgets", "ssh", "alpha"] }` | Opens a new terminal tab and types the command into its shell once the prompt is ready, followed by Enter. |
| `open_url` | `"https://alpha.acme.example/"` | Opens the URL in the default browser. |
| `copy` | `"https://alpha.acme.example/"` | Puts the text on the clipboard as plain text. |

Validation:

- `open_tab.command` is a non-empty array of non-empty strings with no control characters. Cortland quotes each element for a POSIX shell (letters, digits, and `@%+=:,./_-` stay bare; anything else goes in single quotes) and joins them with spaces.
- `open_url` is an `http` or `https` URL with a non-empty host and no control characters.
- `copy` is a non-empty string.

Any violation rejects the whole result: no effect is carried out and the failure alert shows the reason. Present effects run in the order `open_tab`, `open_url`, `copy`. Unknown keys are ignored.

## Palette entries

The command palette lists the entries of every enabled extension, in sidebar order (by extension name), each extension's entries in manifest order. The entry's icon is the panel's SF Symbol, or a generic puzzle piece when the panel icon is a file.

Choosing an entry runs `<command> panel` fresh. If that fails, an alert shows the reason. Otherwise:

- `pick = false`: Cortland looks for a top-level panel action with the entry's `action` id and runs it, exactly as a click in the panel would (including `confirm`). An action with a `menu` is run directly here: the palette ignores `menu`.
- `pick = true`: Cortland collects the rows, across all sections, that have a row action with that id, and shows them in a picker (title, detail as the second line, type to filter, Escape to cancel). Picking one runs that row's action with its row id.

When the action is not in the output (or no row has it), an alert shows the output's `message`, or `This command is not available right now.` when there is none.

## Refresh

- `panel` runs when the panel becomes the visible sidebar panel, then every `refresh_seconds` while it stays visible. A hidden panel, or a hidden sidebar, stops the timer.
- Runs never overlap: a refresh due while one is running is skipped.
- After every action, success or failure, from the panel or the palette, the panel refreshes once it has been opened in this session; if a run is in flight, one more runs after it.
- The Refresh button runs `panel` now.
- The panel redraws only when the output differs from what it shows.

## Install, enable, disable, uninstall

- **Publish**: one git repository per extension, with `extension.toml` at the repository root. The repository's folder name does not matter: the install folder is named from `id`.
- **Install from a URL**: Preferences → Extensions → **Install from URL…**, or `cortland-ctl extension install <url>`. Cortland runs `git clone --depth 1` into a hidden staging folder in the extensions folder, reads `id`, validates the whole manifest, then moves the clone to `~/.config/cortland/extensions/<id>`. It fails, leaving nothing behind, when the manifest is missing or invalid or when anything already exists at that path. It never runs `command`. A new extension starts disabled.
- **Install while developing**: put a symlink to your working folder at `~/.config/cortland/extensions/<id>`. Edits take effect without reinstalling.
- **Update**: Preferences → Extensions → **Update**, or `cortland-ctl extension update <id>`. Runs `git pull --ff-only` in the folder. Only a real folder (not a symlink) that contains `.git` can be updated, so only those rows have an Update button. Enabled state does not change. A manifest that stops validating after the pull is still an update; the extension is then listed as invalid.
- **Git**: Cortland runs `git` from your shell's PATH with `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` and no terminal prompts, so a clone that needs a password, a key passphrase, or a host-key answer fails at once.
- **Discover**: Cortland scans the extensions folder at launch, each time Preferences → Extensions is shown, and when its Reload button is clicked.
- **Enable**: check **Enabled** under the extension in Preferences → Extensions. Its icon joins the activity bar after the built-in panels, and its palette entries join the palette.
- **Disable**: uncheck **Enabled**. The panel and its palette entries go away.
- **Uninstall**: click **Remove** and confirm. Cortland disables it and moves `~/.config/cortland/extensions/<id>` to the Trash.
- Enabled state is kept outside the extension folders, so replacing an extension's files does not change whether it is enabled. Edits to `bin/run` take effect on its next run; edits to `extension.toml` take effect on the next scan.

## `cortland-ctl extension validate <folder>`

Asks the running Cortland to check a folder with its real validator and decoders. The folder can be anywhere and need not be installed, but its name must equal the id. A relative path is resolved against the current directory.

1. Validates `extension.toml`. A failure is an error, and the check stops.
2. With a `[panel]`, runs `<command> panel` exactly as the sidebar does and decodes the output. A failed run or invalid output is an error.
3. When step 2 succeeded, warns about each `pick = false` entry whose `action` is not a panel action in the output, and each `pick = true` entry whose `action` is on no row.
4. Warns about a `panel.icon` that is not a file and names no SF Symbol, and about any row or action `icon` that names no SF Symbol.

It prints JSON:

```json
{
  "valid": true,
  "errors": [],
  "warnings": [],
  "manifest": {
    "id": "acme.widgets",
    "name": "Widgets",
    "version": "0.1.0",
    "api_version": 1,
    "panel_title": "Widgets",
    "palette": ["New Widget", "Open Widget"]
  },
  "panel": { "sections": 1, "rows": 3, "actions": 1, "message": "3 widgets, 1 stopped" }
}
```

`manifest` is present when the manifest parsed. `panel` is present when the panel ran and decoded; `panel_title` and `message` only when they exist. Exit status 0 when valid (warnings allowed), 1 when invalid or when Cortland cannot be reached. A Cortland build older than this command answers `Unknown command: extension_validate`.

Palette warnings reflect one run: a panel that is logged out offers no actions, so its palette entries warn. Validate again with a live session before trusting those warnings.

## `cortland-ctl extension install <url>`

Asks the running Cortland to install an extension from a git repository (see "Install from a URL" above). The URL is sent as typed: an empty one, one that starts with `-`, or one with a control character is rejected before git runs. A local path must be absolute, because Cortland runs git, not the shell you typed in.

It prints JSON:

```json
{ "id": "acme.widgets", "name": "Widgets", "version": "0.1.0", "enabled": false }
```

Exit status 0 on success. On failure it prints the reason on stderr (for a failed clone, git's own error line) and exits 1.

## `cortland-ctl extension update <id>`

Asks the running Cortland to update an extension installed from a URL (see "Update" above). It prints JSON:

```json
{ "id": "acme.widgets", "updated": true, "version_before": "0.1.0", "version_after": "0.2.0" }
```

`updated` is true when the checkout's commit changed. `version_before` and `version_after` are the manifest's `version`, absent when the manifest did not validate at that point. `invalid` appears only when the manifest no longer validates after the pull, and holds the reason. Exit status 0 on success, including an update that left the manifest invalid. On failure (unknown id, a symlinked or non-git folder, a pull that is not a fast-forward) it prints the reason on stderr and exits 1.
