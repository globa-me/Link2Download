# Link2Download

Native macOS and Windows desktop app for downloading video/audio from YouTube, Vimeo, TikTok, Instagram, and other services supported by `yt-dlp`.

## Download for macOS

Current stable version: **1.3.0**.

- [Download Link2Download-Installer.dmg](https://github.com/globa-me/Link2Download/releases/latest/download/Link2Download-Installer.dmg)
- [Download the optional unblock helper](https://github.com/globa-me/Link2Download/releases/latest/download/Enable_Link2Download.command)
- [View release notes](CHANGELOG.md)

The app is ad-hoc signed but is **not notarized with an Apple Developer ID**. macOS may ask you to approve it once. This is expected for this release.

### Install and open the downloaded app

1. Open the downloaded `Link2Download-Installer.dmg`.
2. Drag `Link2Download.app` to the `Applications` shortcut in the installer window.
3. Eject the installer and open **Applications → Link2Download** once. If macOS blocks it, choose **Done** in the warning.
4. Open **System Settings → Privacy & Security**, scroll to the security message for Link2Download, and click **Open Anyway**.
5. Confirm with your Mac password or Touch ID, then click **Open**.

You only need to approve this copy of the app once. There is no need to lower the global “Allow applications from” security setting.

If **Open Anyway** is not shown, run `Enable_Link2Download.command` from the mounted installer (or the separate download) and enter your administrator password when requested. The helper copies the app to `/Applications` when needed, removes its quarantine attribute, adds a local Gatekeeper rule, and launches it. Use the helper only when it came from this repository’s [GitHub Releases](https://github.com/globa-me/Link2Download/releases).

Advanced fallback, when the app is already in `/Applications`:

```bash
sudo xattr -dr com.apple.quarantine /Applications/Link2Download.app
open /Applications/Link2Download.app
```

## Build it yourself on a Mac

Building from source avoids the downloaded-app approval prompt in the normal case. The build script automatically targets the architecture of the Mac that runs it (Apple Silicon or Intel).

### What you need

- macOS 12 or newer
- Internet access (to download `yt-dlp`, `ffmpeg`, and `ffprobe`)
- Xcode Command Line Tools
- about 1 GB of free space

### Steps for a first-time builder

1. Open **Terminal** (Applications → Utilities).
2. Install Apple’s command-line developer tools. A dialog may open; complete it, then return to Terminal:

   ```bash
   xcode-select --install
   ```

3. Download the source and enter its folder:

   ```bash
   git clone https://github.com/globa-me/Link2Download.git
   cd Link2Download
   ```

4. Download the runtime tools that will be included inside the app:

   ```bash
   ./scripts/fetch_runtime_tools.sh
   ```

5. Compile the app and start it:

   ```bash
   ./scripts/build_app.sh
   open build/Link2Download.app
   ```

6. Optional: create the same DMG-style installer used for releases:

   ```bash
   ./scripts/build_dmg.sh
   open build/Link2Download-Installer.dmg
   ```

Build outputs are kept in `build/` and are not committed to Git. To rebuild after updating the source, run `git pull`, then repeat steps 4–6. If a runtime binary does not match your Mac’s architecture, rerun `./scripts/fetch_runtime_tools.sh` on that Mac before building.

## Current macOS features

- Native SwiftUI interface (light + dark mode)
- One active download at a time, with history, search, retry and cancellation
- Video/audio formats, quality selection, subtitles, extra audio tracks and speed limits
- Open file, reveal in Finder, copy or open the source URL, and delete downloaded files
- Browser-cookie source selection for private/watch-later content
- English, Russian, Hindi and Chinese UI languages

## Runtime tools and advanced build details

The automatic runtime-tool download is the easiest option:

```bash
./scripts/fetch_runtime_tools.sh
```

- On Apple Silicon, it downloads ARM64 static `ffmpeg` and `ffprobe` builds.
- On Intel Macs, it downloads Intel builds.
- The script prints the architecture it found. It must match the Mac compiling the app.

If you already have compatible tools installed locally, embed them instead:

```bash
./scripts/prepare_embedded_tools.sh
```

Optional overrides:

```bash
YTDLP_BIN=/abs/path/yt-dlp FFMPEG_BIN=/abs/path/ffmpeg FFPROBE_BIN=/abs/path/ffprobe ./scripts/prepare_embedded_tools.sh
```

Build outputs:

- `build/Link2Download.app`
- `build/Link2Download-Installer.dmg`
- `build/Enable_Link2Download.command`

## Windows port

The native Windows implementation lives under `windows/` and uses `.NET 8` + `WPF`.

- Solution: `windows/Link2Download.Windows.sln`
- Main projects: `windows/src/Link2Download.Windows.App`, `windows/src/Link2Download.Windows.Core`, and `windows/src/Link2Download.Windows.Infrastructure`
- Windows setup and build instructions: [windows/README.md](windows/README.md)
- Porting plan: [docs/windows-port-plan.md](docs/windows-port-plan.md)

The current Windows code includes a strict single-download queue, persisted settings/history, runtime integration, diagnostics that redact URL secrets, and browser-cookie access disabled by default. The standalone Windows package remains a preview release until it is rebuilt with the current runtime tools on Windows.

## Project structure

- `Sources/` — macOS app source code
- `Resources/` — macOS icon, helper, and embedded runtime-tool directory
- `scripts/` — macOS build and packaging scripts
- `CHANGELOG.md` — release notes and version history
- `docs/windows-port-plan.md` — Windows migration plan and feature map
- `windows/` — Windows app source, runtime layout, and handoff documentation
- `build/` — generated local artifacts (ignored by Git)

## Important legal note

Use the app only in compliance with platform terms, local law, and content rights.
