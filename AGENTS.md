# Repository Guide

## Current State
- This repository currently contains a macOS-only desktop app implemented in SwiftUI.
- The shipping macOS source lives in `Sources/`.
- macOS build and packaging scripts live in `scripts/`.
- macOS CLI/MCP contracts and transport live in `Control/`; the native helper lives in `CLI/`.
- Keep both app and helper compatible with macOS 12. The bundled helper is named `link2download-cli`: `link2download` would collide with `Link2Download` on case-insensitive APFS.
- There is no shared cross-platform layer yet.

## Windows Port Target
- Build the Windows version as a separate codebase under `windows/`.
- Preferred stack: `.NET 8` + `WPF`.
- Preserve product behavior and feature parity where it makes sense.
- Do not try to compile or reuse SwiftUI/AppKit code on Windows.

## Read First
- `README.md`
- `docs/automation.md` (macOS CLI/MCP architecture, contracts, checks and verification limits)
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
- `Sources/AutomationController.swift`: CLI/MCP command routing into the app-owned manager and settings.
- `Control/ControlCatalog.swift`: canonical command schemas shared by the app, CLI and MCP.
- `Sources/Link2DownloadApp.swift`: AppKit lifecycle, background launch and single-owner lease; hosts the existing SwiftUI views.

## macOS Automation Invariants
- GUI, CLI and MCP share one app-owned `DownloadManager` and `SettingsStore`; clients must not write history/preferences directly.
- There is one active download and one active transcode, which can run concurrently.
- Original request preferences and current-attempt preferences have separate persisted identities. Preserve both when changing retry/deduplication.
- Test with isolated UserDefaults/history/logs and a private control endpoint; see `docs/automation.md`.
- Updating source on GitHub is separate from publishing a new binary release. Record actual signing/notarization and runtime results without claiming an unperformed macOS 12 runtime test.

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
