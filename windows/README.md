# Windows Workspace

This folder contains the native Windows version of Link2Download.

## What Is Here

- `Link2Download.Windows.sln`: Windows solution
- `src/Link2Download.Windows.App`: WPF application shell and view models
- `src/Link2Download.Windows.Core`: queue, models, settings shape, history model
- `src/Link2Download.Windows.Infrastructure`: JSON persistence, diagnostics, `yt-dlp` runtime integration
- `tests/Link2Download.Windows.Tests`: queue, persistence, parser tests
- `bootstrap_windows_solution.ps1`: idempotent bootstrap for regenerating the solution structure
- `CODEX_TASK.md`: original Codex handoff task
- `runtime/`: expected runtime-tool layout

## Recommended Environment On Windows

- Windows 11
- `.NET 8 SDK`
- Visual Studio 2022 with desktop development for `.NET`
- Git
- PowerShell 7 or Windows PowerShell

## Bootstrap

Run this from the repository root on the Windows laptop:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\bootstrap_windows_solution.ps1
```

After that, open the generated solution under `windows/`.

If the solution already exists, the script simply validates and fills in any missing projects/references.

## Runtime Tool Layout

Expected location for external tools:

```text
windows/runtime/win-x64/yt-dlp.exe
windows/runtime/win-x64/ffmpeg.exe
windows/runtime/win-x64/ffprobe.exe
```

Keep the binaries replaceable. Do not hardcode system-only install paths as the primary strategy.

Optional but useful:

- `deno.exe` on `PATH` for compatibility with some newer `yt-dlp` YouTube extraction flows

The app does not hardcode `deno.exe`, but `yt-dlp` can use it automatically when present.

## Build And Run

From the repository root:

```powershell
dotnet build .\windows\Link2Download.Windows.sln
dotnet run --project .\windows\src\Link2Download.Windows.App
```

## Portable Publish

To create the current portable Windows package with a single launchable `.exe`:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\publish-portable.ps1
```

Output:

- `windows\dist\Link2Download-Windows-Portable\Link2Download.exe`
- `windows\dist\Link2Download-Windows-Portable.zip`

The portable build no longer requires `Start Link2Download.cmd`. Runtime tools are bundled into the app and extracted automatically to `%LocalAppData%\Link2Download\runtime\win-x64` on first launch. If `deno.exe` is present in `windows/runtime/win-x64` when you publish, it is bundled alongside the other runtime tools as well.

## Persistence

- settings: `%AppData%\Link2Download\settings.json`
- history: `%AppData%\Link2Download\history.json`
- diagnostics log: `%LocalAppData%\Link2Download\logs\app.log`

## First Build Goal

The first meaningful Windows milestone should be:

- a runnable WPF shell
- one queue manager
- persisted settings/history
- download flow wired to `yt-dlp.exe`

Read `../docs/windows-port-plan.md` before starting implementation.
