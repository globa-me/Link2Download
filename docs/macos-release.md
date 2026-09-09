# macOS Developer ID release

## Handoff status — 2026-09-09

- Developer ID Application identity is installed: `Developer ID Application: Gennadiy Zakharov (BN3D9H4C7J)`.
- `scripts/build_app.sh` now signs each embedded Mach-O tool explicitly, then the app, with hardened runtime and secure timestamps. Original files in `Resources/bin` remain unchanged.
- `Resources/yt-dlp.entitlements` disables library validation only for the upstream PyInstaller yt-dlp executable, whose extracted Python libraries do not share our Team ID. The Swift app and ffmpeg/ffprobe do not receive this exception.
- Version 1.4.2 now builds as Universal 2 by default. The app, `yt-dlp`, `ffmpeg`, and `ffprobe` each contain both `arm64` and `x86_64` slices. The runtime downloader uses pinned URLs and mandatory SHA-256 checks before combining ARM64 ffmpeg 8.0 with Intel ffmpeg 9.0.1 as fat binaries.
- A Developer ID signed Universal 2 app was built successfully. Strict app and individual tool signature checks passed; signed `yt-dlp`, `ffmpeg`, and `ffprobe` version commands succeeded for both architectures. Shell syntax and git whitespace checks passed. The `Link2Download` Keychain profile is configured and validated. Apple accepted app submission `dd85cb66-278f-4c46-b8b4-7fe7ca093b43` and DMG submission `6efe6eaf-d376-4974-88f7-0ab9e6b9e4a4`. Both tickets are stapled and validated; Gatekeeper accepts both app and DMG.
- `scripts/build_dmg.sh` preserves the old local/ad-hoc packaging by default. `RELEASE_DMG=1` requires a stapled app and creates a signed DMG containing the app and Applications shortcut, with no Gatekeeper bypass helpers or instructions.
- `scripts/notarize_release.sh` coordinates app notarization, stapling, DMG packaging, DMG notarization, stapling and Gatekeeper checks. The entire live workflow passed. The Developer ID preflight captures verbose codesign output before checking it, avoiding pipefail/SIGPIPE from an early-exiting grep.
- Existing public v1.4.1 download documentation remains unchanged because v1.4.2 has not been published to GitHub yet. Only the DMG that passes all final checks is a release artifact.

## Verified artifact

- File: `build/Link2Download-Installer.dmg` (139,854,972 bytes, about 133 MiB), version 1.4.2, Universal 2, macOS 12+.
- SHA-256: `7bed4d08e8e80356cf52fb5c83ce7a7b541f5e863614f925e31d2a7820347b41`.
- App and DMG notarization: Accepted. App log has no issues. Receipts and service logs are in `build/notary-*`.
- Image checksum verification passed. Mounted image contains only app and Applications shortcut as visible items; no bypass helper/instructions.
- The app copied out of the final image passes strict code-signature checks and stapler validation. Gatekeeper accepts a copy marked with download quarantine.
- Real partial YouTube downloads through the bundled `yt-dlp` and `ffmpeg` succeeded for the native ARM64 path and for the x86_64 path under Rosetta, including video/audio merging (`build/youtube-runtime-smoke.5dpobV` and `build/youtube-runtime-intel-smoke.k2lDJM`). The signed app process also launched successfully with both forced architectures.
- Checks ran on an Apple Silicon development Mac. A physical Intel Mac, clean-Mac installation, and offline first launch were not tested. Rosetta execution provides strong Intel-slice coverage but does not replace a final smoke test on Intel hardware before publication.
- Do not rebuild over this artifact with the default ad-hoc build/DMG commands when distributing it. Regenerate using the release script below.

## One-time credential setup

Create an app-specific password in your Apple Account (https://account.apple.com), then run locally in Terminal:

```bash
xcrun notarytool store-credentials Link2Download --apple-id global_corp@mail.ru --team-id BN3D9H4C7J
```

Enter the app-specific password at the hidden interactive prompt. Do not put passwords in chat, repository files, command arguments, or logs. Substitute the Apple Account email if the membership uses a different account.

## Build a release

```bash
SIGNING_IDENTITY='Developer ID Application: Gennadiy Zakharov (BN3D9H4C7J)' ./scripts/notarize_release.sh
```

The release script downloads the pinned Universal 2 runtime, verifies all checksums, builds and signs both architectures, checks that every required executable contains both slices, and executes both runtime architectures before submission. Use `NOTARY_PROFILE=other-name` to select an existing profile. `SKIP_BUILD=1` reuses the signed app already in build (only use if source and runtime have not changed).

Successful output: `build/Link2Download-Installer.dmg` and `.dmg.sha256`. Only distribute after the script reports `Ready for distribution`. Finder automation is used to arrange the installer window.

Notarization receipts: `build/notary-app.plist`, `build/notary-dmg.plist`. Rejection logs: `build/notary-*-log.json`. If interrupted during Apple's processing, inspect the submission ID/history with `xcrun notarytool history --keychain-profile Link2Download` and query `info`/`log` for that ID before resubmitting.

Before public release, test on a clean Mac with download quarantine intact, including offline first launch after stapling, opening the DMG, drag-install, and a real download. Replace the public README install section and omit the old unblock helper from release assets only when the notarized DMG is actually published.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [PyInstaller macOS signing](https://pyinstaller.org/en/stable/feature-notes.html).
