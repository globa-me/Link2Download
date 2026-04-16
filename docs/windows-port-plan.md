# Windows Port Plan

## Goal

Create a full Windows desktop version of Link2Download without disrupting the existing macOS app. The Windows app should match the current product behavior closely enough that users can switch platforms without relearning the workflow.

## Recommended Stack

- UI: `WPF` on `.NET 8`
- Architecture: app shell + core logic + infrastructure
- Runtime tools: `yt-dlp.exe`, `ffmpeg.exe`, `ffprobe.exe`
- Persistence: JSON files in user app-data folders
- Packaging later: MSIX or a simple installer after the app is stable

Why this stack:
- native Windows desktop UI
- mature tooling
- easy process execution and file-system integration
- good Codex ergonomics on a Windows laptop

## Product Parity Baseline

The Windows version should preserve these behaviors first:

1. Paste a supported link and enqueue a job quickly.
2. Process only one active download at a time.
3. Persist download history with metadata and file paths.
4. Search/filter the history list.
5. Support video and audio download modes.
6. Support quality presets, output formats, save folder, speed limit, subtitles, and extra audio tracks.
7. Offer item actions:
   - open file
   - show in Explorer
   - copy source URL
   - open source in browser
   - delete downloaded file
   - remove item from list
8. Keep diagnostics and user-readable error states.

## macOS To Windows Mapping

Reference the current macOS source, but do not mirror it mechanically.

- `Sources/Models.swift`
  - Port to C# enums, DTOs, and record models.
- `Sources/SettingsStore.swift`
  - Port settings storage and smart-profile logic.
  - Store settings in JSON under `%AppData%\\Link2Download\\settings.json`.
- `Sources/DownloadManager.swift`
  - Port queueing, retry/cancel behavior, list filters, and history persistence.
  - Persist history under `%AppData%\\Link2Download\\history.json`.
- `Sources/YTDLPService.swift`
  - Rebuild process execution in C# with structured stdout/stderr parsing.
  - Resolve Windows tool paths from `windows/runtime/win-x64/` first.
- `Sources/AppLocalization.swift`
  - Reuse the localization key set.
  - Phase 1 can ship English first if needed, but keep the string key structure ready for Russian.
- `Sources/BrowserCookieExporter.swift`
  - Do not port this implementation literally.
  - On Windows, prefer `yt-dlp --cookies-from-browser chrome|edge|firefox`.
- `Sources/AppDiagnostics.swift`
  - Log to `%LocalAppData%\\Link2Download\\logs\\app.log`.
- `Sources/MainView.swift`
  - Use as a feature and layout reference, not as a direct component map.

## Important Product Decisions

- The macOS app has Apple-specific transcode wording and behavior.
- The Windows version should not expose Apple-focused labels.
- Recommended handling:
  - phase 1: focus on download parity and manual transcoding support
  - phase 2: add a Windows-friendly "compatibility transcode" option if still needed

## Suggested Windows Solution Layout

```text
windows/
  Link2Download.Windows.sln
  bootstrap_windows_solution.ps1
  README.md
  CODEX_TASK.md
  runtime/
    README.md
    win-x64/
  src/
    Link2Download.Windows.App/
    Link2Download.Windows.Core/
    Link2Download.Windows.Infrastructure/
  tests/
    Link2Download.Windows.Tests/
```

## Implementation Order

### Phase 1: Project bootstrap
- create the WPF solution
- create Core/Infrastructure/Test projects
- wire project references
- commit the empty runnable shell

### Phase 2: Shared domain and persistence
- port enums and record models
- port settings DTO and smart defaults
- implement JSON settings/history storage
- add tests for serialization and filter logic

### Phase 3: Runtime integration
- implement process runner for `yt-dlp` and `ffmpeg`
- implement metadata fetch and progress parsing
- support cancellation and retry
- support Windows browser-cookie mode through `yt-dlp`

### Phase 4: UI parity
- build main window, filters, history rows, and settings dialog
- add clipboard paste flow
- add Explorer/browser actions
- add empty/error states

### Phase 5: Packaging
- decide on MSIX or installer
- bundle runtime tools or add first-run download
- add release build documentation

## Expected Acceptance Criteria For The First Real Windows Milestone

- the app launches on Windows
- a pasted YouTube URL can be downloaded successfully
- completed items are visible after restart
- queueing enforces one active download
- user can open the file and open the folder from the app
- settings survive restart

## Risk Notes

- Browser-cookie behavior is platform-specific and should be treated as its own integration surface.
- FFmpeg/yt-dlp bundling may affect antivirus or SmartScreen behavior later.
- WPF project creation must happen on a Windows machine with desktop tooling installed.
