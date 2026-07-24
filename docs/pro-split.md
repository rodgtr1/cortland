# The free / Pro split

Cortland ships in two shapes from one source tree. This repo is the free core:
MIT, public, and a complete working terminal on its own. Four surfaces have a
paid layer on top, and that layer lives in a separate private package so it is
never in public source.

Nothing is gated by a licence yet. Today the split is purely structural.

## What differs

| Surface | This repo | Official build |
| --- | --- | --- |
| Session Recall (⌃⇧S) | Teaser panel: the ten most recent sessions as title + "agent · repo · age", with the true total underneath. Read-only — no search field, no ⌘↩ preview, rows aren't selectable. | The full panel: text search, deep transcript-body search, ⌘↩ preview, the All/Claude/Codex filter, Enter to resume. |
| Approval desk | The edit gate fails open. `show_diff` is answered with no verdict, the hook prints no permission decision, and Claude Code uses its own prompt — the same thing that happens when Cortland isn't running. The agents panel has no approvals section. | The review queue, the `[approval]` policy, "approve & remember" grants, and the cards at the top of the agents panel. |
| Cost reporting | Telemetry without money: the live context bar, agent state, model and turn counts. No `$` on any row, no session roll-up footer, no spend history. | The per-row figure, the roll-up with its per-model tooltip, and `~/.config/cortland/session-costs.jsonl`. |
| One-step worktree launch | Create, open, remove and merge a worktree. Creating opens a plain terminal in the new checkout. | The create sheet's agent picker: make the worktree and start Claude/Codex/Pi in it as one action. |

Everything agents touch is identical in both: the IPC wire contract, the helper
binaries (`cortland-ctl`, `cortland-agent-status`, `cortland-mcp`,
`cortland-telemetry`), `CortlandIPCCore/EditGate.swift`, and hook installation.
An agent cannot tell the two builds apart except by what a human sees.

## The mechanism

Three pieces:

**`CortlandProInterface/`** — a small SwiftPM package in this repo holding the
seam: four protocols, the `ProFeatures` registry that stores their (optional)
implementations, the value types they exchange, the shared panel chrome, and the
session-log parsers both recall panels read. It depends on nothing but AppKit.

It is its own package rather than a target of this one because the private
package has to import it, and a private package that imported the root package
would give SwiftPM a cycle.

**`ProFeatures`** — every slot starts nil, and nil means free:

```swift
if let recall = ProFeatures.recall {
    recall.showRecall(relativeTo: window, resume: …)
    return
}
showSessionsTeaser()
```

Free paths are real code, not stubs that trap. Removing the Pro package does not
remove a feature's plumbing — it changes which of two real behaviors runs.

**`CORTLAND_PRO_PATH`** — `Package.swift` is Swift, so it reads the environment:

```swift
let proPath = ProcessInfo.processInfo.environment["CORTLAND_PRO_PATH"]
```

When set, the package dependency, the app target's dependency on `CortlandPro`,
and `-DCORTLAND_PRO` all appear together. When unset, none of them exist. The
only `import CortlandPro` in this repo sits inside `#if CORTLAND_PRO` in
`Sources/Cortland/Pro/ProBridge.swift`; a public clone compiles that file with
the condition undefined and the registry stays empty.

## Which way dependencies point

The Pro package depends on the seam and on nothing else — not on this app
target, which SwiftPM could not express anyway. So the app hands *down*
everything Pro needs from it:

- the theme palette (`ProTheme.colors`, republished on every theme change)
- number formatting for spend and tokens (`TelemetryFormat`, so both sides
  render `$0.36` identically)
- a log sink, so a Pro build writes one log file rather than two
- for the desk, an `ApprovalDeskContext`: the live `[approval]` settings, the
  window to review in, the pane's worktree root, the event sink, the
  parked-status flip, and diff rendering

Config parsing, the tab tree, git, the syntax engine and the IPC server all stay
here. Pro reads their results, never their internals.

## Building

```sh
swift build                                        # free
./build-app.sh                                     # Pro, if ../cortland-pro exists
CORTLAND_PRO=0 ./build-app.sh                      # free, deliberately
CORTLAND_PRO_PATH=/elsewhere ./build-app.sh        # Pro, from elsewhere
```

`build-app.sh` defaults `CORTLAND_PRO_PATH` to `../cortland-pro`, so an official
build on a machine with both checkouts needs no environment. It fails loudly if
the path is missing rather than quietly shipping a free app as a release.
`notarize.sh` and `make-appcast.sh` are unchanged — they operate on the bundle
`build-app.sh` produced and don't care which one it is.

## Testing

```sh
swift test              # free suite
./scripts/test-all.sh   # free + Pro, in one run, with the combined count
```

SwiftPM will neither run a dependency's tests nor accept a target path outside
the package root, so `scripts/test-all.sh` symlinks the Pro test target to
`Tests/CortlandProTests` (gitignored) and `Package.swift` declares that target
only when both the environment variable and the link are present. Plain
`swift test` with no environment is unaffected and is what a public clone runs.

## Adding a Pro feature

1. Write the free behavior first, in this repo, as real code.
2. Add a protocol and a `ProFeatures` slot in `CortlandProInterface`.
3. Branch on the slot at the point of use, never once at startup — registration
   happens during `applicationDidFinishLaunching`, after some callers exist.
4. Implement it in the private package and register it in `CortlandPro.register()`.
5. Test the free path here and the Pro path there.

If Pro needs something the app owns, pass it in through the provider's
`install(…)` rather than moving the app's code into the seam. The seam should
stay a vocabulary, not a second application.
