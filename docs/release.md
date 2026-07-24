# Cutting a release build

The exact commands that produce a notarized, self-updating, distributable
build. The notarization half was first proven 2026-07-21 (both submissions
Accepted; `spctl` reports "Notarized Developer ID" for the app and the DMG).
The Sparkle half landed in v0.7.0.

## One-time setup

- Developer ID Application certificate in the login keychain
  (`Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)`).
- Stored notary credentials (prompts for an app-specific password from
  account.apple.com):

  ```sh
  xcrun notarytool store-credentials sidekick-notary \
      --apple-id <apple-id> --team-id 2UWZ923R8C
  ```

- An EdDSA signing key for Sparkle. One key covers every release forever, so
  this is run once and never again:

  ```sh
  .build/artifacts/sparkle/Sparkle/bin/generate_keys
  ```

  It stores the private key in the login Keychain and prints the public half.
  The public half is already in `Info.plist` as `SUPublicEDKey`; the private
  half must never be written into this repo or any file. Re-running the tool
  finds the existing key rather than replacing it. Losing the key means no
  existing install can ever be updated again — back it up with
  `generate_keys -x <file>`, store that file somewhere safe off this machine,
  and delete it from disk.

## Per release

### 1. Bump the version

Both keys in `Info.plist`, together. `CFBundleShortVersionString` is what
people see; `CFBundleVersion` is the monotonic number Sparkle compares, formula
minor × 100 + patch (see `docs/release-baseline.md`). It must only ever go up:
an install on a higher build number will never see the release as an update.

### 2. Write the release notes (optional)

`docs/release-notes/<version>.md`, e.g. `docs/release-notes/0.7.0.md`. If the
file exists, `make-appcast.sh` embeds it in the appcast and Sparkle shows it in
the update dialog before anyone installs. If it doesn't, the update still works
and the dialog links to the full CHANGELOG.

### 3. Build, notarize, generate the appcast

```sh
RELEASE=1 ./build-app.sh    # build, embed + sign Sparkle.framework, sign app
                            # + 4 helpers + DMG with Developer ID, hardened
                            # runtime, timestamps
./scripts/notarize.sh       # submit app archive, staple .app, rebuild
                            # zip + DMG from the stapled app, notarize and
                            # staple the DMG, spctl-assess both
./scripts/make-appcast.sh   # sign the stapled DMG with the Keychain EdDSA key
                            # and write build/appcast.xml
```

Order matters: `make-appcast.sh` signs whatever `build/Cortland.dmg` currently
is, so it has to run **after** stapling. Running it before means shipping a
signature for a DMG nobody downloads.

It writes two files:

| File | Role |
| --- | --- |
| `build/appcast.xml` | The feed. One item, describing this release. |
| `build/Cortland-<version>.dmg` | The archive the feed's enclosure URL names. |

### 4. Publish

Tag and upload. **These commands are the release; run them by hand when the
build is good.**

```sh
gh release create v0.7.0 \
    --title "Cortland 0.7.0" \
    --notes-file docs/release-notes/0.7.0.md \
    build/Cortland.dmg \
    build/Cortland-0.7.0.dmg \
    build/appcast.xml
```

Attaching a file to an existing release instead:

```sh
gh release upload v0.7.0 build/appcast.xml --clobber
```

All three attachments matter:

- `Cortland.dmg` — the unversioned name for the download link on the site.
- `Cortland-0.7.0.dmg` — the exact filename the appcast's enclosure URL points
  at (`…/releases/download/v0.7.0/Cortland-0.7.0.dmg`). Renaming or deleting it
  breaks every in-app update.
- `appcast.xml` — the feed itself, at
  `…/releases/latest/download/appcast.xml`, which is the `SUFeedURL` baked into
  every shipped build. GitHub resolves `latest` to the newest non-prerelease
  release, so a **prerelease will not be served to anyone**. Publish as a full
  release when the update should go out.

### 5. Confirm the feed

```sh
curl -sL https://github.com/rodgtr1/cortland/releases/latest/download/appcast.xml
```

The `<sparkle:version>` in the response must be the new build number, and the
enclosure URL must return 200.

## How updates reach people

`Info.plist` carries `SUFeedURL` (the fixed `releases/latest/download/`
address) and `SUPublicEDKey` (the public half of the signing key). Sparkle
starts with the app, asks once whether it may check automatically, and from
then on checks on its own schedule. Nothing installs silently: the user always
sees the version and an Install button. "Check for Updates…" in the Cortland
menu forces a check at any time.

Every download is verified against `SUPublicEDKey` before it is installed, so a
tampered or substituted archive is rejected even if someone controls the
download URL. That check is what makes it safe for the feed to be a plain
public URL.

The appcast the tool generates carries `<sparkle:hardwareRequirements>arm64`,
because `swift build` produces a binary for the build machine's architecture
only. Intel Macs will correctly see "no update available" rather than a broken
one. Shipping universal builds is a separate piece of work.

## Testing the update path without publishing

Proven locally on 2026-07-24. Sparkle allows plain http only for `localhost`,
which is enough to run the whole path offline:

1. Copy `build/Cortland.app` twice into a temp directory. In each copy's
   `Info.plist`, set a throwaway `CFBundleIdentifier` (so the real app's
   preferences and the running instance are untouched), give one a lower
   `CFBundleVersion` than the other, and point `SUFeedURL` at
   `http://localhost:8917/appcast.xml`. Re-sign both copies afterwards —
   editing the plist breaks the seal:

   ```sh
   codesign --force --options runtime --entitlements Cortland.entitlements \
       --sign "Sidekick Dev" <copy>/Cortland.app
   ```

2. Zip the newer copy, generate a feed for it, and serve the directory:

   ```sh
   ditto -c -k --keepParent new/Cortland.app archives/Cortland-0.5.1.zip
   .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
       --download-url-prefix http://localhost:8917/ archives
   (cd archives && python3 -m http.server 8917 --bind 127.0.0.1)
   ```

3. Launch the older copy from the temp directory and use "Check for Updates…".
   Never point this at `/Applications/Cortland.app` or at a running instance —
   a second instance takes over the IPC socket at
   `~/.config/cortland/cortland.sock` from the first.

To check the rejection path too, append a byte to the served archive without
regenerating the feed. Sparkle must refuse it with "The update is improperly
signed and could not be validated."

## Dev builds

Unchanged: plain `./build-app.sh` signs with the local `Sidekick Dev` identity
so TCC grants persist across rebuilds, and never touches the notary service.
That identity and the `sidekick-notary` keychain profile keep their pre-rename
names on purpose — renaming either would throw away the TCC grants and stored
credentials attached to them.

If a notary submission is rejected, read Apple's reasons:

```sh
xcrun notarytool log <submission-id> --keychain-profile sidekick-notary
```

## Before shipping to anyone

Copy the DMG to another Mac (or a fresh macOS user account), download-style
(browser or AirDrop so it gets quarantined), and confirm it opens, installs,
and launches without a Gatekeeper override.
