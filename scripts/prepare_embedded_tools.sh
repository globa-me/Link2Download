#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT_DIR/Resources/bin"

YTDLP_BIN="${YTDLP_BIN:-$(command -v yt-dlp || true)}"
FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg || true)}"
FFPROBE_BIN="${FFPROBE_BIN:-$(command -v ffprobe || true)}"
DENO_BIN="${DENO_BIN:-$(command -v deno || true)}"

if [[ -z "$YTDLP_BIN" || ! -x "$YTDLP_BIN" ]]; then
  echo "yt-dlp binary not found. Set YTDLP_BIN=/absolute/path/to/yt-dlp"
  exit 1
fi

if [[ -z "$FFMPEG_BIN" || ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found. Set FFMPEG_BIN=/absolute/path/to/ffmpeg"
  exit 1
fi

if [[ -z "$DENO_BIN" || ! -x "$DENO_BIN" ]]; then
  echo "deno binary not found. Set DENO_BIN=/absolute/path/to/deno"
  exit 1
fi

mkdir -p "$BIN_DIR"
cp "$YTDLP_BIN" "$BIN_DIR/yt-dlp"
# Official onedir yt-dlp needs its complete adjacent Python runtime.
if [[ -d "$(dirname "$YTDLP_BIN")/_internal" ]]; then
  rm -rf "$BIN_DIR/_internal"
  ditto "$(dirname "$YTDLP_BIN")/_internal" "$BIN_DIR/_internal"
fi
cp "$DENO_BIN" "$BIN_DIR/deno"
cp "$FFMPEG_BIN" "$BIN_DIR/ffmpeg"

if [[ -n "$FFPROBE_BIN" && -x "$FFPROBE_BIN" ]]; then
  cp "$FFPROBE_BIN" "$BIN_DIR/ffprobe"
fi

chmod +x "$BIN_DIR/yt-dlp" "$BIN_DIR/ffmpeg" "$BIN_DIR/deno"
if [[ -f "$BIN_DIR/ffprobe" ]]; then
  chmod +x "$BIN_DIR/ffprobe"
fi

echo "Embedded tools copied to $BIN_DIR"
echo "Check portability of copied binaries before release (otool -L)."
