# Repository Guide

## Current State
- This repository currently contains a macOS-only desktop app implemented in SwiftUI.
- The shipping macOS source lives in `Sources/`.
- macOS build and packaging scripts live in `scripts/`.
- There is no shared cross-platform layer yet.

## Windows Port Target
- Build the Windows version as a separate codebase under `windows/`.
- Preferred stack: `.NET 8` + `WPF`.
- Preserve product behavior and feature parity where it makes sense.
- Do not try to compile or reuse SwiftUI/AppKit code on Windows.

## Read First
- `README.md`
- `docs/windows-port-plan.md`
- `windows/README.md`
- `windows/CODEX_TASK.md`

## Source Mapping
- `Sources/Models.swift`: domain enums, record structures, persisted settings shape.
- `Sources/SettingsStore.swift`: settings persistence, smart defaults, profile resolution.
- `Sources/DownloadManager.swift`: queueing, retries, cancellation, history, filtering.
- `Sources/YTDLPService.swift`: process orchestration around `yt-dlp` and `ffmpeg`.
- `Sources/AppLocalization.swift`: localization keys and current English/Russian strings.
- `Sources/MainView.swift`: UI behavior reference only.
- `Sources/BrowserCookieExporter.swift`: macOS-specific implementation; replace on Windows.
- `Sources/AppDiagnostics.swift`: logging behavior and retention policy.

## Windows Constraints
- Keep the existing macOS app working. Do not break `Sources/` or `scripts/`.
- Put new Windows-specific code, tools, and docs under `windows/`.
- Keep runtime binaries out of git unless there is a clear reason.
- Expected Windows runtime tool location: `windows/runtime/win-x64/`.
- Favor a pragmatic structure over heavy abstraction.

## Recommended Windows Solution Shape
- `windows/src/Link2Download.Windows.App`: WPF shell and views.
- `windows/src/Link2Download.Windows.Core`: models, settings contracts, queue logic.
- `windows/src/Link2Download.Windows.Infrastructure`: process runners, persistence, file system, browser integration.
- `windows/tests/Link2Download.Windows.Tests`: unit tests for queueing, settings, parsing, and persistence.

## Product Guidance
- Preserve these core behaviors first:
  - paste link and start download
  - one active download at a time
  - persisted history with search and filtering
  - open file / show in Explorer / copy source URL / open source URL
  - settings for kind, quality, format, save folder, speed limit, cookies, subtitles
- Do not port Apple-specific wording literally.
- The macOS "Apple MOV" optimization should become a Windows-friendly compatibility/transcode story or be deferred until the rest of the app is working.

## Runtime Guidance For Windows
- Prefer `yt-dlp --cookies-from-browser` on Windows before implementing browser-cookie extraction manually.
- Keep `yt-dlp.exe`, `ffmpeg.exe`, and `ffprobe.exe` external and replaceable.
- Log process output and persist app diagnostics in a user-writable app-data directory.

## First Windows Session
- Start by reading the files in `Read First`.
- Run `powershell -ExecutionPolicy Bypass -File .\windows\bootstrap_windows_solution.ps1` on the Windows machine.
- Then implement the first runnable WPF shell and migrate queue/runtime logic incrementally.
