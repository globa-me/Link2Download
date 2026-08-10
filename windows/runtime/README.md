# Windows Runtime Tools

Place Windows runtime binaries here when the Windows port starts implementation.

## Expected Files

```text
windows/runtime/win-x64/yt-dlp.exe
windows/runtime/win-x64/ffmpeg.exe
windows/runtime/win-x64/ffprobe.exe
```

These binaries are intentionally not committed yet.

Historical local runtime used during early Windows-port work on 2026-04-16:

- `yt-dlp.exe` `2026.03.17`
- `ffmpeg.exe`
- `ffprobe.exe`

The current repository folder only keeps `windows/runtime/win-x64/.gitkeep`; add fresh replaceable `.exe` files before running or publishing the Windows app.

For some newer YouTube extraction flows, `yt-dlp` may also benefit from `deno.exe` being installed on `PATH`, but it is not copied into this folder by default.
