# Link2Download (macOS)

Native macOS desktop app for downloading video/audio from YouTube, Vimeo, TikTok, Instagram, and other services supported by `yt-dlp`.

## Windows Port

- Native Windows implementation lives under `windows/`.
- Stack:
  - `.NET 8` + `WPF`
- Solution:
  - `windows/Link2Download.Windows.sln`
- Main projects:
  - `windows/src/Link2Download.Windows.App`
  - `windows/src/Link2Download.Windows.Core`
  - `windows/src/Link2Download.Windows.Infrastructure`
  - `windows/tests/Link2Download.Windows.Tests`
- Start with:
  - `docs/windows-port-plan.md`
  - `windows/README.md`
  - `windows/CODEX_TASK.md`

Current Windows milestone on this branch:
- runnable WPF shell
- strict single-download queue
- persisted settings/history in `%AppData%\\Link2Download`
- `yt-dlp` / `ffmpeg` runtime integration from `windows/runtime/win-x64/`
- unit tests for queue, persistence, and progress parsing

## Download (latest DMG)

- Latest release: https://github.com/globa-me/Link2Download/releases/latest
- Download DMG: https://github.com/globa-me/Link2Download/releases/latest/download/Link2Download-Installer.dmg
- Unblock helper script: https://github.com/globa-me/Link2Download/releases/latest/download/Enable_Link2Download.command

Verified on 2026-04-16:
- Current release page (`v1.0.0`): https://github.com/globa-me/Link2Download/releases/tag/v1.0.0
- Direct DMG (`v1.0.0`): https://github.com/globa-me/Link2Download/releases/download/v1.0.0/Link2Download-Installer.dmg
- Direct helper script (`v1.0.0`): https://github.com/globa-me/Link2Download/releases/download/v1.0.0/Enable_Link2Download.command

## Current scope

- Native SwiftUI interface (light + dark mode, light-blue visual theme)
- `Paste Link` button reads URL from clipboard and starts download automatically
- Single active download at a time (strict queue with max concurrency = 1)
- Download history with metadata (duration, format, quality, size, path)
- Search in history by title/source URL/creator
- Thumbnail + creator name shown when metadata is available
- Context actions per item:
  - Open file
  - Show in Finder
  - Copy source URL
  - Open source in browser
  - Delete downloaded file
  - Remove item from list
- Preferences:
  - Smart mode (auto parameters by service)
  - Download type (video/audio)
  - Quality (Best/720p/1080p/4K/8K)
  - Video format (MP4/MKV) or audio format (MP3/M4A/OGG)
  - Save folder (default `~/Documents/Link2Download`)
  - Speed limit (Unlimited/50/25/10/4 Mbps)
  - Optional browser cookies source (Safari/Chrome/Chromium/Firefox/Edge) for private/watch-later content
  - Subtitle and additional audio track toggles
  - Language (System, English, Russian, Hindi, Chinese)

## Important legal note

Use the app only in compliance with platform terms, local law, and content rights.

## Prerequisites (builder machine)

- macOS 12+
- Xcode command line tools (`xcode-select --install`)
- Local binaries for:
  - `yt-dlp`
  - `ffmpeg`
  - `ffprobe` (recommended)

## Build flow

### 1) Embed runtime tools into app resources

Option A (auto-download binaries):

```bash
./scripts/fetch_runtime_tools.sh
```

Notes:
- On Apple Silicon, the script downloads ARM64 static `ffmpeg/ffprobe` builds.
- On Intel Macs, it downloads Intel static builds.
- The script prints detected binary architecture after download.

Current upstream targets verified on 2026-04-16:
- `yt-dlp_macos` latest -> `2026.03.17`: https://github.com/yt-dlp/yt-dlp/releases/download/2026.03.17/yt-dlp_macos
- Intel `ffmpeg` latest -> `ffmpeg-8.1.zip`: https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip
- Intel `ffprobe` latest -> `ffprobe-8.1.zip`: https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip
- Apple Silicon `ffmpeg` archive: https://www.osxexperts.net/ffmpeg80arm.zip
- Apple Silicon `ffprobe` archive: https://www.osxexperts.net/ffprobe80arm.zip

Option B (copy from local system):

```bash
./scripts/prepare_embedded_tools.sh
```

Optional overrides:

```bash
YTDLP_BIN=/abs/path/yt-dlp FFMPEG_BIN=/abs/path/ffmpeg FFPROBE_BIN=/abs/path/ffprobe ./scripts/prepare_embedded_tools.sh
```

### 2) Build `.app`

```bash
./scripts/build_app.sh
```

Output:

- `build/Link2Download.app`

### 3) Build DMG installer

```bash
./scripts/build_dmg.sh
```

Output:

- `build/Link2Download-Installer.dmg`
- `build/Enable_Link2Download.command`

## Unsigned app install (no Developer ID / notarization)

Inside DMG package:

1. Drag `Link2Download.app` to `Applications`
2. Try opening `Link2Download.app` from `Applications`
3. If blocked, open `System Settings -> Privacy & Security -> Open Anyway`
4. Confirm with Mac password or Touch ID, then launch app again
5. If `Open Anyway` does not appear, run `Enable_Link2Download.command`

Manual fallback commands:

```bash
sudo xattr -dr com.apple.quarantine "/Volumes/Link2Download Installer"
sudo xattr -dr com.apple.quarantine "/Volumes/Link2Download Installer/Enable_Link2Download.command"
sudo xattr -dr com.apple.quarantine /Applications/Link2Download.app
sudo spctl --add --label "Link2Download Local" /Applications/Link2Download.app
open /Applications/Link2Download.app
```

## Project structure

- `Sources/` - macOS app source code
- `Resources/` - runtime helper files
- `Resources/bin/` - embedded `yt-dlp` and `ffmpeg` binaries
- `scripts/` - build and packaging scripts
- `docs/windows-port-plan.md` - Windows migration plan and feature map
- `windows/` - Windows bootstrap files, runtime layout, and Codex handoff
- `build/` - generated artifacts
