# Changelog

## 1.4.1 — 2026-09-04

### macOS

- Updated the embedded `yt-dlp` runtime to `2026.08.19`.
- Forced the stable `tv_embedded` YouTube client instead of combining transient player-client format lists; verified both public and Chrome-cookie format discovery at 1080p.
- Excluded transient YouTube Premium and SABR formats from automatic and explicit format selection.
- Added bounded HTTP, fragment, and extractor retries for temporary delivery failures.
- Preserved the most relevant YouTube download error when a later browser-cookie source cannot be read.
- Verified the affected YouTube video with yt-dlp's short download test before installation.
- Redesigned the main window with adaptive layouts for narrow, compact, and wide sizes.
- Simplified Smart mode, manual controls, filtering, and completed-download actions.
- Added repeatable UI snapshot checks for six window-size and mode combinations.

## 1.4.0 — 2026-08-19

### macOS

- Updated embedded `yt-dlp` runtime binary to the latest official release.
- Added YouTube player client extractor arguments (`ios,mweb,web,default`) to prevent HTTP 403 Forbidden stream throttling.
- Sanitized internal protocol markers (`__L2D_*`) from process errors to keep UI error displays and logs clean.
- Added automatic browser-cookie fallback for HTTP 403 Forbidden and rate-limited streams.
- Improved explicit format selector retry when browser cookies expose restricted formats.
- Added localized user-friendly hints for YouTube HTTP 403 Forbidden errors across all supported languages.

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
