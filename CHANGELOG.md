# Changelog

## 1.3.0 — 2026-08-10

### macOS

- Prevent video downloads without an audio stream from being retained as successful downloads.
- Prefer yt-dlp formats that explicitly contain both video and audio.
- Remove stale temporary `.tmp.mov` files left by interrupted Apple-compatible conversions.
- Build natively on both Apple Silicon and Intel Macs.

### Windows

- Disable browser-cookie access by default.
- Redact URL query strings and fragments from diagnostics.
- Verify the hash of embedded runtime tools before extracting them again.

## 1.1.0 — 2026-04-21

- Windows preview release: native .NET 8 + WPF portable app.

## 1.0.0 — 2026-03-17

- First public macOS release.
