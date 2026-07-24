# Cutting a release build

The exact commands that produce a notarized, distributable build. First run
proven 2026-07-21 (both notary submissions Accepted; `spctl` reports
"Notarized Developer ID" for the app and the DMG).

## One-time setup

- Developer ID Application certificate in the login keychain
  (`Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)`).
- Stored notary credentials (prompts for an app-specific password from
  account.apple.com):

  ```sh
  xcrun notarytool store-credentials sidekick-notary \
      --apple-id <apple-id> --team-id 2UWZ923R8C
  ```

## Per release

```sh
RELEASE=1 ./build-app.sh    # build, then sign app + 4 helpers + DMG with
                            # Developer ID, hardened runtime, timestamps
./scripts/notarize.sh       # submit app archive, staple .app, rebuild
                            # zip + DMG from the stapled app, notarize and
                            # staple the DMG, spctl-assess both
```

Ship `build/Cortland.dmg` (or `build/Cortland.zip`). The `.app` is stapled
before the containers are rebuilt, so first launch passes Gatekeeper even
offline.

If a submission is rejected, read Apple's reasons:

```sh
xcrun notarytool log <submission-id> --keychain-profile sidekick-notary
```

Dev builds are unchanged: plain `./build-app.sh` signs with the local
`Sidekick Dev` identity so TCC grants persist across rebuilds; it never
touches the notary service. That identity and the `sidekick-notary` keychain
profile keep their pre-rename names on purpose — renaming either would throw
away the TCC grants and stored credentials attached to them.

## Before shipping to anyone

Copy the DMG to another Mac (or a fresh macOS user account), download-style
(browser or AirDrop so it gets quarantined), and confirm it opens, installs,
and launches without a Gatekeeper override.
