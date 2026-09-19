# macOS release runbook

This document describes the current Developer ID release process. Version-specific changes belong in [CHANGELOG.md](../CHANGELOG.md); runtime investigation notes are in [intel-runtime-fix.md](intel-runtime-fix.md).

## Current release verification

Version 1.4.4 was built from commit `af065a3` as a Universal 2 app on 2026-09-19. The app and DMG were accepted by Apple notarization, stapled, validated and accepted by Gatekeeper. Isolated YouTube smoke downloads passed through both the native Apple Silicon runtime and the Intel runtime under Rosetta.

Release DMG SHA-256: `0f47479d91d5f95ce2eedb2b08f7266012b8ac107c2b258ce9761ef3bcd54c95`.

## Requirements

- A macOS machine with Xcode Command Line Tools.
- A valid `Developer ID Application` identity in Keychain.
- An Apple notarization profile created with `xcrun notarytool store-credentials`.
- Internet access for pinned runtime downloads and Apple notarization.

Never commit Apple Account credentials, app-specific passwords, notarization receipts or private logs.

## Runtime layout

Current builds use the official yt-dlp onedir distribution. Keep `_internal` next to `yt-dlp`; the old one-file binary is not a compatible replacement. Deno is bundled for YouTube JavaScript challenges, while ffmpeg and ffprobe remain replaceable runtime tools.

The scripts verify checksums and required architectures. Deno and yt-dlp receive only their required entitlements; other binaries and the app use the normal hardened-runtime signature.

## Prepare credentials

Create an app-specific password in the Apple Account portal, then store it interactively in Keychain:

```bash
xcrun notarytool store-credentials Link2Download \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID
```

The scripts use the `Link2Download` profile by default. Set `NOTARY_PROFILE` to select another existing profile.

## Build signed architecture-specific archives

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/build_signed_macos_variants.sh
```

Outputs are written under `build/`. They are not public release artifacts until notarization and installation checks pass.

## Build and notarize the DMG

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/notarize_release.sh
```

The workflow downloads pinned runtime tools, verifies checksums and architectures, signs nested code and the app, submits the app and DMG to Apple, staples tickets, and runs signature and Gatekeeper checks.

Only distribute the DMG after the script reports `Ready for distribution`. Final outputs:

- `build/Link2Download-Installer.dmg`
- `build/Link2Download-Installer.dmg.sha256`

`SKIP_BUILD=1` may reuse an existing signed app only when neither source nor runtime changed.

## Release checklist

1. Run the shell, retry/history and runtime-process regression checks from the main README.
2. Run the isolated YouTube smoke test for both target architectures.
3. Complete notarization and verify the generated checksum.
4. Test the stapled DMG with download quarantine intact on a clean Mac.
5. Confirm drag-install, first launch, a real download and an offline launch.
6. Prefer a physical Intel smoke test before publishing an Intel artifact.
7. Create the GitHub tag and release only after all published assets pass.
8. Update stable-version and installation wording in the same release change.

Notarization receipts and service logs remain local under `build/`. If submission is interrupted, use `xcrun notarytool history`, then inspect the existing submission with `info` or `log` before resubmitting.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [PyInstaller macOS signing](https://pyinstaller.org/en/stable/feature-notes.html).
