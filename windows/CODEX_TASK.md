# Codex Task For The Windows Laptop

Use this repository to build the first real Windows version of Link2Download.

## Ground Rules

- Keep the existing macOS app untouched and working.
- Build the Windows version under `windows/`.
- Use `.NET 8` + `WPF` unless there is a strong technical blocker.
- Treat the Swift code in `Sources/` as the product specification and logic reference.
- Start by reading:
  - `AGENTS.md`
  - `docs/windows-port-plan.md`
  - `windows/README.md`

## Immediate Actions

1. Run `powershell -ExecutionPolicy Bypass -File .\\windows\\bootstrap_windows_solution.ps1`.
2. Create the Windows solution and base projects if they do not exist yet.
3. Port the core domain models and settings/history persistence first.
4. Build a runnable WPF shell with a placeholder main window.
5. Then implement the first working download flow using `yt-dlp.exe` from `windows/runtime/win-x64/`.

## Required Product Behavior

- single active download at a time
- persisted history with search/filter
- paste link flow
- video/audio modes
- quality and format settings
- open file / show in Explorer / copy source URL / open source URL
- diagnostics logging

## Important Notes

- Do not port Apple-specific UI labels directly into the Windows app.
- Prefer `yt-dlp --cookies-from-browser` on Windows before custom cookie extraction.
- Add tests for queueing, persistence, and progress parsing when you move logic into C#.
