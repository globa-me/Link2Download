# Windows Workspace

This folder prepares the repository for a native Windows port of Link2Download.

## What Is Here

- `bootstrap_windows_solution.ps1`: creates the initial Windows solution and base projects
- `CODEX_TASK.md`: a ready-to-paste task prompt for Codex on a Windows machine
- `runtime/`: expected layout for Windows runtime binaries

## What Is Not Here Yet

- no runnable Windows app yet
- no `.sln` yet
- no bundled Windows binaries yet

Those pieces should be created on the Windows machine after cloning the repository.

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

## Runtime Tool Layout

Expected location for external tools:

```text
windows/runtime/win-x64/yt-dlp.exe
windows/runtime/win-x64/ffmpeg.exe
windows/runtime/win-x64/ffprobe.exe
```

Keep the binaries replaceable. Do not hardcode system-only install paths as the primary strategy.

## First Build Goal

The first meaningful Windows milestone should be:

- a runnable WPF shell
- one queue manager
- persisted settings/history
- download flow wired to `yt-dlp.exe`

Read `../docs/windows-port-plan.md` before starting implementation.
