# macOS release runbook

This document describes the current Developer ID release process. Version-specific changes belong in [CHANGELOG.md](../CHANGELOG.md); runtime investigation notes are in [intel-runtime-fix.md](intel-runtime-fix.md).

## Current release verification

### Installed transcode cancellation update — 2026-10-24

The transcode cancellation fix is installed and running at `/Applications/Link2Download.app` as **1.4.5 (241026.1)**, Universal 2. Its bundle and final ZIP are `build/transcode-cancellation/Link2Download.app` and `build/transcode-cancellation/Link2Download-Transcode-Cancellation-macOS.zip`. No public GitHub release was published.

- Developer ID G2 identity `6E99F92E9A1BA1273CD084FAFE940A7280DB0A30`, team `BN3D9H4C7J`, Hardened Runtime and secure timestamps.
- Apple profile `GZB-notary`: **Accepted**, submission `e327ef3f-805a-45f5-adbe-88c106085344`. Stapling/validation, signature verification and Gatekeeper passed for the source app, installed app and final ZIP-extracted app (`Notarized Developer ID`).
- Final ZIP was recreated after stapling. SHA-256: `9fc2a59960d88430aaf69a9107a28205afc574d95b0c8b0abf532fedb7464fbd`.
- The signed build passed the isolated live suite on **ARM64 and Intel under Rosetta**, including cancellation after actual VideoToolbox progress, unchanged source bytes, temporary MOV cleanup, CLI/MCP, video/M4A/MOV, persistence and shutdown/restart. Deterministic cancellation fixtures passed on both architectures. Automation, retry/history, process runner, 12 CLI/MCP protocol checks, eight compatibility fixtures and nine UI snapshots passed. All 109 bundled Mach-O images retain minimum macOS <= 12. Actual macOS 12 and physical Intel were not tested.
- The old app quit without forcing/cancelling work. The new installed build reports 57 history records and a visible window through the existing MCP connection. All 57 record IDs and every persisted record field were retained, and download settings are semantically unchanged.
- Previous apps and private before/after state snapshots are kept under ignored `build/transcode-cancellation/installation/` (directory mode 0700). Do not commit them or the submission ZIP/notary receipt.

Reproduce from the repository root (the notarization ID and checksum above apply only to this actual build):

```bash
./scripts/test_transcode_cancellation.sh
TEST_ARCH=x86_64 ./scripts/test_transcode_cancellation.sh
SIGNING_CERT_SHA1=6E99F92E9A1BA1273CD084FAFE940A7280DB0A30 \
  APP_BUILD=241026.1 BUILD_DIR="$PWD/build/transcode-cancellation" ./scripts/build_app.sh
python3 scripts/check_macos_compatibility.py build/transcode-cancellation/Link2Download.app
python3 scripts/test_automation_live.py --app build/transcode-cancellation/Link2Download.app --arch arm64
python3 scripts/test_automation_live.py --app build/transcode-cancellation/Link2Download.app --arch x86_64
ditto -c -k --sequesterRsrc --keepParent build/transcode-cancellation/Link2Download.app build/transcode-cancellation/submission.zip
xcrun notarytool submit build/transcode-cancellation/submission.zip --keychain-profile GZB-notary --wait --timeout 20m
# Continue only after Accepted.
xcrun stapler staple build/transcode-cancellation/Link2Download.app
xcrun stapler validate build/transcode-cancellation/Link2Download.app
codesign --verify --strict --verbose=2 build/transcode-cancellation/Link2Download.app
spctl --assess --type execute --verbose=4 build/transcode-cancellation/Link2Download.app
ditto -c -k --sequesterRsrc --keepParent build/transcode-cancellation/Link2Download.app build/transcode-cancellation/Link2Download-Transcode-Cancellation-macOS.zip
shasum -a 256 build/transcode-cancellation/Link2Download-Transcode-Cancellation-macOS.zip
```

Recheck the final ZIP-extracted app before installation, stop the installed app only when idle, and retain a rollback copy and state snapshots. See [cancellation architecture and checks](automation.md#transcode-cancellation--2026-10-24) before changing worker lifetime or output commit behavior.

### Installed automation preview — 2026-10-24

The Claude Code schema compatibility fix was rebuilt as Universal 2, app version **1.4.5 (241026)**, and installed at `/Applications/Link2Download.app`. At that verification date the local bundle and archive were `build/Link2Download.app` and `build/Link2Download-Automation-Preview-macOS.zip`. No new public GitHub binary release was published on that date.

- Developer ID G2 identity `6E99F92E9A1BA1273CD084FAFE940A7280DB0A30`, team `BN3D9H4C7J`, Hardened Runtime and secure timestamps.
- Apple notarization profile `GZB-notary`: **Accepted**, submission `f9c88016-d593-4929-99bb-2f6ce4c4aa19`. The ticket was stapled and validated. Source, installed and final ZIP-extracted apps passed signature and Gatekeeper checks as `Notarized Developer ID`.
- Final archive (recreated after stapling) SHA-256: `58e22d1c2d843d0e79bac215b9684be85c2217d1ba8f025b4fc68f1b8c51dd31`.
- All 109 bundled Mach-O images retain minimum OS <= macOS 12 on arm64 and x86_64. The rebuilt app passed isolated ARM64 video/M4A/MOV, native MCP, persistence and shutdown/restart checks on macOS 26.7.1. The prior preview also passed Intel under Rosetta; actual macOS 12 and physical Intel remain untested.
- The final installed build passed five actual Codex MCP calls using its persistent user configuration. Claude Code 2.1.308 connects and discovers all 29 tools; an authenticated Claude model session was not performed. On 2026-10-25, the user accepted the completed checks as sufficient and waived further Claude model verification. See [installed client verification](automation.md#installed-client-verification--2026-10-24).
- The old installed app, original state/config snapshots and prior preview remain privately backed up under ignored `build/installation-20261024/`. All 56 original history record IDs and every record field are retained; app startup applies its existing history ordering. Persistent download preferences are unchanged.

To reproduce, use the normal preview commands below with `APP_BUILD=241026`. Any rebuild requires its own notarization submission and resulting archive checksum; never reuse the recorded ticket for changed binaries.

### Local automation preview — 2026-10-23

The CLI/MCP implementation was verified as a local Universal 2 preview at `build/Link2Download-Automation-Preview-macOS.zip`. On that date this was not a new GitHub binary release, and the public stable release was 1.4.5. The preview retained app version 1.4.5 with build 231026.

- App and `Contents/MacOS/link2download-cli` are signed with G2 identity `6E99F92E9A1BA1273CD084FAFE940A7280DB0A30`, team `BN3D9H4C7J`, Hardened Runtime and secure timestamps.
- Apple notarization using Keychain profile `GZB-notary`: **Accepted**, submission `ea22b552-8fae-49a4-b0be-bb2c3fb6d75a`.
- The ticket was stapled and validated, the signature verified, and Gatekeeper accepted the app as `Notarized Developer ID`. The final ZIP was recreated after stapling and its extracted app rechecked.
- Final ZIP SHA-256: `2555e5992ed0544e7c5b79bf1ea07724bab9a183afeff1f57645a364fe6d299e`.
- All 109 bundled Mach-O images declare minimum OS versions <= macOS 12.0. Live CLI/MCP video, M4A, Apple MOV, shutdown/restart and official SDK checks passed on ARM64 and Intel under Rosetta on macOS 26.7.1. Actual macOS 12 and physical Intel remain untested. See [automation verification](automation.md#verification-on-2026-10-23).

Reproduce the preview with the normal signed build, then submit the app ZIP with the known profile:

```bash
SIGNING_CERT_SHA1=6E99F92E9A1BA1273CD084FAFE940A7280DB0A30 \
  MIN_MACOS_VERSION=12.0 TARGET_ARCH=universal2 ./scripts/build_app.sh
python3 scripts/check_macos_compatibility.py build/Link2Download.app
ditto -c -k --sequesterRsrc --keepParent build/Link2Download.app build/Link2Download-automation-submission.zip
xcrun notarytool submit build/Link2Download-automation-submission.zip \
  --keychain-profile GZB-notary --wait --timeout 20m
# Continue only after Accepted; inspect the notary log on rejection.
xcrun stapler staple build/Link2Download.app
xcrun stapler validate build/Link2Download.app
codesign --verify --deep --strict build/Link2Download.app
spctl --assess --type execute --verbose=4 build/Link2Download.app
ditto -c -k --sequesterRsrc --keepParent build/Link2Download.app build/Link2Download-Automation-Preview-macOS.zip
shasum -a 256 build/Link2Download-Automation-Preview-macOS.zip
```

The submission ZIP, notary receipts and private diagnostics stay under ignored `build/`. Distribute only the final ZIP made after stapling. For public releases continue to follow the complete installer checklist below.

### Stable release history

Version 1.4.5 was built from commit `0ea7fa9` as a Universal 2 app on 2026-09-24. The app and DMG were accepted by Apple notarization, stapled, validated and accepted by Gatekeeper. Isolated YouTube download and merge smoke tests passed for Apple Silicon and Intel under Rosetta. The app was installed and launched from `/Applications`.

Release DMG SHA-256: `b2b100566535ca9d92bc8e37ed8ddb5af7ba8a9ca6a1ecd696c7af7180f2e3d0`.


Version 1.4.4 was built from commit `af065a3` as a Universal 2 app on 2026-09-19. The app and DMG were accepted by Apple notarization, stapled, validated and accepted by Gatekeeper. Isolated YouTube smoke downloads passed through both the native Apple Silicon runtime and the Intel runtime under Rosetta.

Release DMG SHA-256: `0f47479d91d5f95ce2eedb2b08f7266012b8ac107c2b258ce9761ef3bcd54c95`.

## Requirements

- A macOS machine with Xcode Command Line Tools.
- A valid G2 `Developer ID Application` identity and private key for team `BN3D9H4C7J` in Keychain.
- An Apple notarization profile created with `xcrun notarytool store-credentials`.
- Internet access for pinned runtime downloads and Apple notarization.

Never commit Apple Account credentials, app-specific passwords, notarization receipts or private logs.

## Runtime layout

Current builds use the official yt-dlp onedir distribution. Keep `_internal` next to `yt-dlp`; the old one-file binary is not a compatible replacement. Deno is bundled for YouTube JavaScript challenges, while ffmpeg and ffprobe remain replaceable runtime tools.

The scripts verify checksums and required architectures. Deno and yt-dlp receive only their required entitlements; other binaries and the app use the normal hardened-runtime signature.

## Prepare credentials

On the development Mac, use the existing `GZB-notary` Keychain profile directly. Verify it with `xcrun notarytool history --keychain-profile GZB-notary`. Authentication remains in Keychain.

On a new Mac without this profile, create an app-specific password in the Apple Account portal, then store it interactively in Keychain:

```bash
xcrun notarytool store-credentials GZB-notary \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID
```

The scripts use the `GZB-notary` profile by default. Set `NOTARY_PROFILE` to select another existing profile.

Select the G2 leaf certificate with `SIGNING_CERT_SHA1`, its 40-character SHA-1 fingerprint. Names can be identical for old and G2 certificates. `scripts/check_release_signing.sh` checks the leaf issuer OU `G2`, team, validity and usable private key before a signed build replaces any output. It also checks the selected leaf and secure timestamp in signed apps and DMGs. Signed builds using only `SIGNING_IDENTITY` are no longer accepted. Local ad hoc builds remain available with the default `./scripts/build_app.sh` command.

The verified G2 configuration and migration history are recorded in [developer-id-g2-migration.md](developer-id-g2-migration.md).

## Build signed architecture-specific archives

```bash
SIGNING_CERT_SHA1='<G2 leaf certificate SHA-1>' \
  ./scripts/build_signed_macos_variants.sh
```

Outputs are written under `build/`. They are not public release artifacts until notarization and installation checks pass.

## Build and notarize the DMG

```bash
SIGNING_CERT_SHA1='<G2 leaf certificate SHA-1>' \
  ./scripts/notarize_release.sh
```

The workflow downloads pinned runtime tools, verifies checksums and architectures, signs nested code and the app, submits the app and DMG to Apple, staples tickets, and runs signature and Gatekeeper checks.

Only distribute the DMG after the script reports `Ready for distribution`. Final outputs:

- `build/Link2Download-Installer.dmg`
- `build/Link2Download-Installer.dmg.sha256`

`SKIP_BUILD=1` may reuse an existing signed app only when neither source nor runtime changed. Its leaf must match `SIGNING_CERT_SHA1`, use G2 and include a secure timestamp.

## Release checklist

1. Run the shell, retry/history and runtime-process regression checks from the main README.
2. Run the isolated YouTube smoke test for both target architectures.
3. Complete notarization and verify the generated checksum.
4. Test the stapled DMG with download quarantine intact on a clean Mac.
5. Confirm drag-install, first launch, a real download and an offline launch.
6. Prefer a physical Intel smoke test before publishing an Intel artifact.
7. Create the GitHub tag and release only after all published assets pass.
8. Update stable-version and installation wording in the same release change.
9. Download the actual GitHub assets into a separate directory, compare their SHA-256 with the release checksum, mount the downloaded DMG, and verify its app signature, stapled ticket, architectures, Gatekeeper result and launch.

Notarization receipts and service logs remain local under `build/`. If submission is interrupted, use `xcrun notarytool history`, then inspect the existing submission with `info` or `log` before resubmitting.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [PyInstaller macOS signing](https://pyinstaller.org/en/stable/feature-notes.html).
