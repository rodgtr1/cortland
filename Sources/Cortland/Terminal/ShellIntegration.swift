import Foundation

/// Writes the Cortland shell-integration scripts to disk and manages their
/// installation into the user's shell rc file.
///
/// The scripts emit:
///  - OSC 7  — the current working directory on every prompt and `cd`,
///             which replaces CWD polling entirely.
///  - OSC 133 — prompt marks: A (prompt drawn), C (command started),
///             D;<exit> (command finished), used for prompt navigation and
///             per-command exit/duration reporting.
enum ShellIntegration {
    static let termProgram = "Cortland"

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/shell-integration")
    }

    static var zshScriptURL: URL { directoryURL.appendingPathComponent("cortland.zsh") }
    static var bashScriptURL: URL { directoryURL.appendingPathComponent("cortland.bash") }

    private static let zshrcMarker = "# Cortland shell integration"
    private static var zshrcSourceLine: String {
        "[[ \"$TERM_PROGRAM\" == \"\(termProgram)\" ]] && source \"$HOME/.config/cortland/shell-integration/cortland.zsh\""
    }

    /// Writes (or refreshes) the script files. Called at app launch so the
    /// on-disk scripts always match the running app.
    static func installScripts() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try zshScript.write(to: zshScriptURL, atomically: true, encoding: .utf8)
            try bashScript.write(to: bashScriptURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("ShellIntegration: failed to write scripts: \(error)", category: "terminal")
        }
        do {
            try installShims()
        } catch {
            // Workers still get the argv injection for direct `--exec claude`
            // launches; only wrapper-hidden launches lose the mode.
            Log.error("ShellIntegration: failed to write worker shims: \(error)", category: "terminal")
        }
    }

    /// Directory of PATH shims for Cortland-launched workers.
    ///
    /// A worker's argv gets the approval flags injected only when its program is
    /// literally `claude`/`codex`; a wrapper like `--exec sh -c 'exec claude …'`
    /// hides the program from that injection, and the interactive `claude()`
    /// wrapper can't help either (the inner sh is non-interactive and `exec`
    /// bypasses functions). Worker panes therefore prepend this directory to
    /// PATH, so whichever process in the worker's tree finally resolves
    /// `claude`/`codex` finds a shim that reads the live approval mode and
    /// execs the real binary with the pane-scoped flags.
    static var shimDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/shims")
    }

    /// Writes (or refreshes) the worker shims, marked executable.
    static func installShims(at directory: URL = shimDirectoryURL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in [("claude", claudeShim), ("codex", codexShim)] {
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    /// Contents of ~/.zshrc, or "" when there is no such file. Throws when the
    /// file exists but cannot be read as UTF-8: a failed read must never be
    /// mistaken for empty content, or the append below would rewrite the user's
    /// zshrc as nothing but the Cortland stanza.
    private static func zshrcContents(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// False when ~/.zshrc is absent, and also when it exists but can't be read
    /// — in that case `installInZshrc` throws rather than clobbering it.
    static func isInstalledInZshrc(at url: URL = zshrcURL) -> Bool {
        guard let contents = try? zshrcContents(at: url) else { return false }
        return contents.contains("shell-integration/cortland.zsh")
    }

    /// Appends the source line to ~/.zshrc. Returns false if it was already
    /// present. Throws (leaving the file untouched) if an existing ~/.zshrc
    /// cannot be read.
    ///
    /// A pre-rename stanza is dropped on the way past. It is already inert — its
    /// guard tests `TERM_PROGRAM == "Sidekick"`, which no build sets any more —
    /// but leaving a dead line next to the live one invites the user to debug
    /// the wrong one. Only touched when they ask for an install; nothing here
    /// edits a shell rc file on its own.
    @discardableResult
    static func installInZshrc(at url: URL = zshrcURL) throws -> Bool {
        let contents = try zshrcContents(at: url)
        guard !contents.contains("shell-integration/cortland.zsh") else { return false }

        var kept = removingLegacyStanza(from: contents)
        if !kept.isEmpty && !kept.hasSuffix("\n") {
            kept += "\n"
        }
        kept += "\n\(zshrcMarker)\n\(zshrcSourceLine)\n"
        try kept.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Drops the marker comment and source line an install wrote under the app's
    /// former name, and the blank line they were introduced by. Internal for
    /// tests.
    static func removingLegacyStanza(from contents: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        lines.removeAll { line in
            line.contains("shell-integration/sidekick.zsh")
                || line.trimmingCharacters(in: .whitespaces) == "# Sidekick shell integration"
        }
        // Collapse a run of blank lines the removal opened up mid-file.
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty == true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Script contents

    static let zshScript = #"""
# Cortland shell integration (zsh)
# Emits OSC 7 (working directory) and OSC 133 (prompt/command marks).
# Safe to source from any terminal; it only activates inside Cortland.

[[ "$TERM_PROGRAM" != "Cortland" ]] && return
[[ -n "$CORTLAND_SHELL_INTEGRATION_ACTIVE" ]] && return
typeset -g CORTLAND_SHELL_INTEGRATION_ACTIVE=1

__cortland_report_cwd() {
    printf '\e]7;file://%s%s\e\\' "${HOST:-localhost}" "$PWD"
}

__cortland_preexec() {
    typeset -g __CORTLAND_COMMAND_RAN=1
    # Carry the command line, base64-encoded, in the C mark so Cortland can
    # report it in command records without re-scraping the prompt. tr -d '\n'
    # guards against any line wrapping from base64.
    printf '\e]133;C;%s\e\\' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

__cortland_precmd() {
    local exit_code=$?
    if [[ -n "$__CORTLAND_COMMAND_RAN" ]]; then
        unset __CORTLAND_COMMAND_RAN
        printf '\e]133;D;%s\e\\' "$exit_code"
    fi
    __cortland_report_cwd
    # Reset kitty keyboard-protocol flags at every prompt. A TUI that dies
    # without popping its flags (dropped SSH session, crashed agent CLI)
    # would otherwise leave the pane emitting CSI-u sequences zsh can't read.
    printf '\e[=0;1u'
    printf '\e]133;A\e\\'
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __cortland_precmd
add-zsh-hook preexec __cortland_preexec
add-zsh-hook chpwd __cortland_report_cwd

# Resolve the approval mode at agent launch, not pane launch. Preferences writes
# one data-only word atomically; the env value is a fallback if it is unreadable.
__cortland_approval_mode() {
    local mode="$CORTLAND_APPROVAL_MODE"
    if [[ -n "$CORTLAND_APPROVAL_MODE_FILE" && -r "$CORTLAND_APPROVAL_MODE_FILE" ]]; then
        IFS= read -r mode < "$CORTLAND_APPROVAL_MODE_FILE"
    fi
    [[ "$mode" == "claude-auto" ]] && mode="review"
    printf '%s' "${mode:-ask}"
}

# Apply Cortland's provider-neutral mode only inside Cortland. Explicit caller
# flags always win, so one-off agent launches remain possible.
claude() {
    local arg mode
    for arg in "$@"; do
        case "$arg" in
            --permission-mode|--permission-mode=*) command claude "$@"; return ;;
        esac
    done
    mode="$(__cortland_approval_mode)"
    case "$mode" in
        auto) command claude --permission-mode acceptEdits "$@" ;;
        review) command claude --permission-mode auto "$@" ;;
        bypass) command claude --permission-mode bypassPermissions "$@" ;;
        *) command claude "$@" ;;
    esac
}

codex() {
    local arg prev mode
    prev=""
    for arg in "$@"; do
        case "$arg" in
            --sandbox|--sandbox=*|-s|-s=*|--ask-for-approval|--ask-for-approval=*|-a|-a=*|--full-auto|--yolo|--dangerously-bypass-approvals-and-sandbox|-c=approvals_reviewer=*|--config=approvals_reviewer=*)
                command codex "$@"; return ;;
            # Bare `approvals_reviewer=…` is a caller's own reviewer only as the
            # value of a preceding -c/--config; anywhere else it is prose.
            approvals_reviewer=*)
                case "$prev" in
                    -c|--config) command codex "$@"; return ;;
                esac ;;
        esac
        prev="$arg"
    done
    mode="$(__cortland_approval_mode)"
    # CORTLAND_ACTIVE_APPROVAL_REVIEWER names whoever answers this session's
    # approval requests, for the status hooks Codex spawns: the auto-reviewer
    # answers without the human typing, so its PermissionRequest is not a cue to
    # report "needs input".
    case "$mode" in
        auto) CORTLAND_ACTIVE_APPROVAL_REVIEWER=user command codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=user "$@" ;;
        review) CORTLAND_ACTIVE_APPROVAL_REVIEWER=auto_review command codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=auto_review "$@" ;;
        bypass) CORTLAND_ACTIVE_APPROVAL_REVIEWER=user command codex --sandbox danger-full-access --ask-for-approval never "$@" ;;
        *) CORTLAND_ACTIVE_APPROVAL_REVIEWER=user command codex --sandbox read-only --ask-for-approval on-request -c approvals_reviewer=user "$@" ;;
    esac
}
"""#

    static let bashScript = #"""
# Cortland shell integration (bash)
# Emits OSC 7 (working directory) and OSC 133 (prompt/command marks).
# Safe to source from any terminal; it only activates inside Cortland.

[[ "$TERM_PROGRAM" != "Cortland" ]] && return
[[ -n "$CORTLAND_SHELL_INTEGRATION_ACTIVE" ]] && return
CORTLAND_SHELL_INTEGRATION_ACTIVE=1

__cortland_report_cwd() {
    printf '\e]7;file://%s%s\e\\' "${HOSTNAME:-localhost}" "$PWD"
}

__cortland_preexec() {
    # The DEBUG trap fires for every simple command, including our own
    # PROMPT_COMMAND; only emit C for the first command after a prompt.
    [[ -n "$__CORTLAND_AT_PROMPT" ]] || return 0
    unset __CORTLAND_AT_PROMPT
    __CORTLAND_COMMAND_RAN=1
    # Carry the command line, base64-encoded, in the C mark (see zsh note above).
    printf '\e]133;C;%s\e\\' "$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')"
}

__cortland_precmd() {
    local exit_code=$?
    if [[ -n "$__CORTLAND_COMMAND_RAN" ]]; then
        unset __CORTLAND_COMMAND_RAN
        printf '\e]133;D;%s\e\\' "$exit_code"
    fi
    __cortland_report_cwd
    # Reset kitty keyboard-protocol flags at every prompt (see zsh note above).
    printf '\e[=0;1u'
    printf '\e]133;A\e\\'
    __CORTLAND_AT_PROMPT=1
}

trap '__cortland_preexec' DEBUG
PROMPT_COMMAND="__cortland_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# Resolve the approval mode at agent launch, not pane launch. Preferences writes
# one data-only word atomically; the env value is a fallback if it is unreadable.
__cortland_approval_mode() {
    local mode="$CORTLAND_APPROVAL_MODE"
    if [[ -n "$CORTLAND_APPROVAL_MODE_FILE" && -r "$CORTLAND_APPROVAL_MODE_FILE" ]]; then
        IFS= read -r mode < "$CORTLAND_APPROVAL_MODE_FILE"
    fi
    [[ "$mode" == "claude-auto" ]] && mode="review"
    printf '%s' "${mode:-ask}"
}

# Apply Cortland's provider-neutral mode only inside Cortland. Explicit caller
# flags always win, so one-off agent launches remain possible.
claude() {
    local arg mode
    for arg in "$@"; do
        case "$arg" in
            --permission-mode|--permission-mode=*) command claude "$@"; return ;;
        esac
    done
    mode="$(__cortland_approval_mode)"
    case "$mode" in
        auto) command claude --permission-mode acceptEdits "$@" ;;
        review) command claude --permission-mode auto "$@" ;;
        bypass) command claude --permission-mode bypassPermissions "$@" ;;
        *) command claude "$@" ;;
    esac
}

codex() {
    local arg prev mode
    prev=""
    for arg in "$@"; do
        case "$arg" in
            --sandbox|--sandbox=*|-s|-s=*|--ask-for-approval|--ask-for-approval=*|-a|-a=*|--full-auto|--yolo|--dangerously-bypass-approvals-and-sandbox|-c=approvals_reviewer=*|--config=approvals_reviewer=*)
                command codex "$@"; return ;;
            # Bare `approvals_reviewer=…` is a caller's own reviewer only as the
            # value of a preceding -c/--config; anywhere else it is prose.
            approvals_reviewer=*)
                case "$prev" in
                    -c|--config) command codex "$@"; return ;;
                esac ;;
        esac
        prev="$arg"
    done
    mode="$(__cortland_approval_mode)"
    # CORTLAND_ACTIVE_APPROVAL_REVIEWER names whoever answers this session's
    # approval requests, for the status hooks Codex spawns: the auto-reviewer
    # answers without the human typing, so its PermissionRequest is not a cue to
    # report "needs input".
    case "$mode" in
        auto) CORTLAND_ACTIVE_APPROVAL_REVIEWER=user command codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=user "$@" ;;
        review) CORTLAND_ACTIVE_APPROVAL_REVIEWER=auto_review command codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=auto_review "$@" ;;
        bypass) CORTLAND_ACTIVE_APPROVAL_REVIEWER=user command codex --sandbox danger-full-access --ask-for-approval never "$@" ;;
        *) CORTLAND_ACTIVE_APPROVAL_REVIEWER=user command codex --sandbox read-only --ask-for-approval on-request -c approvals_reviewer=user "$@" ;;
    esac
}
"""#

    // MARK: - Worker shim contents

    /// Shared preamble: drops the shim's own directory from PATH (comparing
    /// physical paths, so a symlinked PATH entry can't leave the shim first and
    /// make it exec itself forever), then resolves the live approval mode the
    /// same way the interactive wrappers do.
    private static let shimPreamble = #"""
shim_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
new_path=
old_ifs=$IFS
IFS=:
for dir in $PATH; do
    phys=$(CDPATH= cd -- "$dir" 2>/dev/null && pwd)
    [ "$phys" = "$shim_dir" ] && continue
    new_path="${new_path:+$new_path:}$dir"
done
IFS=$old_ifs
PATH=$new_path
export PATH

mode="$CORTLAND_APPROVAL_MODE"
if [ -n "$CORTLAND_APPROVAL_MODE_FILE" ] && [ -r "$CORTLAND_APPROVAL_MODE_FILE" ]; then
    IFS= read -r mode < "$CORTLAND_APPROVAL_MODE_FILE"
fi
[ "$mode" = "claude-auto" ] && mode=review
"""#

    /// PATH shim for `claude` in Cortland worker panes. Explicit caller flags
    /// always win; the mode cases mirror the interactive wrapper exactly.
    static let claudeShim = #"""
#!/bin/sh
# Cortland worker shim (claude) — written and refreshed by Cortland at launch.
# Worker panes prepend this directory to PATH so `claude` picks up the pane's
# approval mode even when a wrapper (e.g. `sh -c 'exec claude …'`) hides it
# from Cortland's argv injection.

"""# + shimPreamble + #"""


for arg in "$@"; do
    case "$arg" in
        --permission-mode|--permission-mode=*) exec claude "$@" ;;
    esac
done

case "$mode" in
    auto) exec claude --permission-mode acceptEdits "$@" ;;
    review) exec claude --permission-mode auto "$@" ;;
    bypass) exec claude --permission-mode bypassPermissions "$@" ;;
    *) exec claude "$@" ;;
esac
"""#

    /// PATH shim for `codex` in Cortland worker panes. Same contract as the
    /// claude shim.
    static let codexShim = #"""
#!/bin/sh
# Cortland worker shim (codex) — written and refreshed by Cortland at launch.
# Worker panes prepend this directory to PATH so `codex` picks up the pane's
# approval mode even when a wrapper (e.g. `sh -c 'exec codex …'`) hides it
# from Cortland's argv injection.

"""# + shimPreamble + #"""


prev=""
for arg in "$@"; do
    case "$arg" in
        --sandbox|--sandbox=*|-s|-s=*|--ask-for-approval|--ask-for-approval=*|-a|-a=*|--full-auto|--yolo|--dangerously-bypass-approvals-and-sandbox|-c=approvals_reviewer=*|--config=approvals_reviewer=*)
            exec codex "$@" ;;
        # Bare `approvals_reviewer=…` is a caller's own reviewer only as the
        # value of a preceding -c/--config; anywhere else it is prose.
        approvals_reviewer=*)
            case "$prev" in
                -c|--config) exec codex "$@" ;;
            esac ;;
    esac
    prev="$arg"
done

# See the interactive wrapper: the status hooks Codex spawns inherit this, and
# it is the only way they can tell a machine-answered approval request from one
# the human has to answer.
case "$mode" in
    auto) export CORTLAND_ACTIVE_APPROVAL_REVIEWER=user
        exec codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=user "$@" ;;
    review) export CORTLAND_ACTIVE_APPROVAL_REVIEWER=auto_review
        exec codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=auto_review "$@" ;;
    bypass) export CORTLAND_ACTIVE_APPROVAL_REVIEWER=user
        exec codex --sandbox danger-full-access --ask-for-approval never "$@" ;;
    *) export CORTLAND_ACTIVE_APPROVAL_REVIEWER=user
        exec codex --sandbox read-only --ask-for-approval on-request -c approvals_reviewer=user "$@" ;;
esac
"""#
}
