# Release baseline

Snapshot of the shippable state of Cortland before signing and notarization
work starts. Recorded 2026-07-21 against the `main` working tree at v0.5.0.

Toolchain used for every measurement below:

| Item | Value |
| --- | --- |
| macOS | 26.5.2 |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3), target arm64-apple-macosx26.0 |
| Xcode | 26.6 (17F113) |

## 1. Versioning scheme

`Info.plist` now carries two distinct values. They used to be identical, which
Sparkle cannot work with: it compares `CFBundleVersion` between the running app
and the appcast, and needs a value that only ever increases.

| Key | Value | Role |
| --- | --- | --- |
| `CFBundleShortVersionString` | `0.5.0` | Human-facing version. Exported to every pane as `TERM_PROGRAM_VERSION`, logged at launch. |
| `CFBundleVersion` | `500` | Monotonic build number. Sparkle's upgrade comparison; never shown to a user. |

Build number formula: **minor × 100 + patch**.

| Release | `CFBundleShortVersionString` | `CFBundleVersion` |
| --- | --- | --- |
| 0.5.0 | `0.5.0` | `500` |
| 0.5.1 | `0.5.1` | `501` |
| 0.6.0 | `0.6.0` | `600` |

The formula reserves 100 patch slots per minor release. Bump both keys together
in `Info.plist`; nothing generates them.

One gap to settle before 1.0: the formula ignores the major component, so
`1.0.0` computes to `0` and would go backwards. Extending it to
`major × 10000 + minor × 100 + patch` (making 1.0.0 → `10000`, and 0.5.0 still
`500`) keeps every existing number valid, but that decision belongs to whoever
cuts the first major release.

### Code that reads these keys

A repo-wide grep found two consumers, both already correct:

- `Sources/Cortland/App/AppDelegate.swift:22-24` reads both and writes them to
  the launch log as `version 0.5.0 build 500`. Diagnostic, not user-facing.
- `Sources/Cortland/Terminal/TerminalViewController.swift:784` exports
  `CFBundleShortVersionString` as `TERM_PROGRAM_VERSION` for the shell
  integration script.

No test asserts on either key, and no source file hardcodes `0.5.0` (the only
other match is the TOMLKit dependency floor in `Package.swift`, unrelated).
Nothing had to change outside `Info.plist`, and nothing shows `500` to a user.

Worth knowing for later: the "About Cortland" menu item is built with
`action: nil` (`AppDelegate.swift:113`), so it is inert and no About panel
exists yet. Whenever one gets wired up it must read
`CFBundleShortVersionString`, never `CFBundleVersion`.

## 2. Test-suite baseline

Command: `swift test`

```
Executed 1090 tests, with 1 test skipped and 0 failures (0 unexpected) in 22.067 seconds
```

**No failures to classify.** The historical WorkerShim problem is gone: the
full run shows `WorkerShimTests` at 13 tests, 0 failures, matching the earlier
filtered run.

The single skip is deliberate, not a failure:

| Test | Reason |
| --- | --- |
| `GroveTests.testPrintSampleTrees` | Debug helper that prints grove silhouettes for visual tuning. Guarded by `XCTSkipUnless(env["GROVE_EYEBALL"] != nil)` (`Tests/CortlandTests/GroveTests.swift:260`). Contains no assertions; runs only when opted in. |

The run also prints `SwiftTerm: Unknown OSC code: 133` several times. That is
SwiftTerm logging on the shell-integration sequences the tests feed it, not a
test result.

## 3. Executable inventory

Every Mach-O binary in the bundle, confirmed against the build output rather
than the script alone. Each one needs its own Developer ID signature in the
notarization phase, signed inside-out (helpers first, bundle last).

| Path in bundle | Size | Signing identifier | Purpose |
| --- | --- | --- | --- |
| `Contents/MacOS/Cortland` | 16M | `app.cortland.terminal` | Main app binary |
| `Contents/MacOS/cortland-ctl` | 192K | `cortland-ctl` | Pane-control CLI |
| `Contents/MacOS/cortland-agent-status` | 152K | `cortland-agent-status` | Agent status reporter for hooks |
| `Contents/MacOS/cortland-mcp` | 237K | `cortland-mcp` | MCP server |
| `Contents/MacOS/cortland-telemetry` | 289K | `cortland-telemetry` | Stop-hook token/cost reporter |

Five binaries, no more. The bundle embeds no frameworks and no third-party
dylibs: `otool -L` on the main binary lists only `/usr/lib` and `/System`
paths, so Swift and every dependency link statically. Notarization has nothing
nested to walk beyond `Contents/MacOS`.

Non-executable payload, sealed by the bundle signature:

- `Contents/Info.plist`
- `Contents/Resources/AppIcon.icns`
- `Contents/Resources/skills/cortland-panes/SKILL.md`
- `Contents/Resources/skills/cortland-panes/agents/openai.yaml`

The skill files must be copied in **before** the signing step, since signing
seals `Contents/Resources`. `build-app.sh` already orders it that way.

## 4. Current signing setup

Described as-is. Nothing here was changed in this pass.

- **Identity:** `Sidekick Dev`, a local self-signed codesigning certificate
  created by `scripts/create-signing-cert.sh`. It keeps its pre-rename name so
  the TCC grants bound to it survive. Overridable with the
  `SIGN_IDENTITY` environment variable. `TeamIdentifier=not set`, so the
  signature is developer-local: it survives rebuilds on this machine but means
  nothing to Gatekeeper elsewhere.
- **Why it exists:** a stable cdhash across rebuilds. Ad-hoc signing changes
  the hash every build, and macOS then re-prompts for every TCC grant.
- **Hardened runtime:** on. Both helpers and bundle are signed with
  `--options runtime`; `codesign -dv` reports `flags=0x10000(runtime)` on each.
- **Entitlements:** `Cortland.entitlements`, applied to helpers and bundle
  alike. It sets exactly one key, `com.apple.security.app-sandbox = false`. A
  terminal must spawn arbitrary shells and read the whole filesystem, so the
  sandbox is off by design and the file/network entitlement keys are inert.
- **Order:** the four helpers are signed first, then the bundle, then
  `codesign --verify --deep --strict` checks the result.
- **Distribution artifacts:** `build/Cortland.dmg` (4.6M, drag-to-Applications
  layout) and `build/Cortland.zip` (4.0M, `ditto --keepParent`).

A Developer ID certificate already exists in the keychain
(`Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)`), which is what
the notarization phase will switch `SIGN_IDENTITY` to. Hardened runtime and the
inside-out signing order are already what notarization requires, so that phase
is a change of identity plus a `notarytool` submit and staple, not a rework.

## 5. Build verification

`./build-app.sh` run after the version split. Exit code 0.

```
build/Cortland.app: valid on disk
build/Cortland.app: satisfies its Designated Requirement
✅ Signed. TCC grants will persist across rebuilds.
```

Versions read back off the built bundle:

```
$ plutil -extract CFBundleVersion raw build/Cortland.app/Contents/Info.plist
500
$ plutil -extract CFBundleShortVersionString raw build/Cortland.app/Contents/Info.plist
0.5.0
```

All five helpers validated during signing, and the DMG and zip were produced.
The build is repeatable from a clean checkout with `swift build --configuration
release` plus `./build-app.sh`, the one prerequisite being the `Sidekick Dev`
identity from `scripts/create-signing-cert.sh`; without it the script warns and
falls back to ad-hoc signing rather than failing.
