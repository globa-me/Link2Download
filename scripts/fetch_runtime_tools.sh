#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT_DIR/Resources/bin"
TMP_DIR="$ROOT_DIR/build/runtime-download"

mkdir -p "$BIN_DIR" "$TMP_DIR"

echo "Downloading yt-dlp (official release binary)..."
curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$BIN_DIR/yt-dlp"
chmod +x "$BIN_DIR/yt-dlp"

echo "Downloading ffmpeg + ffprobe (evermeet static builds)..."
curl -L "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o "$TMP_DIR/ffmpeg.zip"
curl -L "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip" -o "$TMP_DIR/ffprobe.zip"

unzip -o "$TMP_DIR/ffmpeg.zip" -d "$TMP_DIR" >/dev/null
unzip -o "$TMP_DIR/ffprobe.zip" -d "$TMP_DIR" >/dev/null

cp "$TMP_DIR/ffmpeg" "$BIN_DIR/ffmpeg"
cp "$TMP_DIR/ffprobe" "$BIN_DIR/ffprobe"
chmod +x "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe"

echo "Runtime tools are ready in: $BIN_DIR"

FFMPEG_ARCH="$(file "$BIN_DIR/ffmpeg" 2>/dev/null || true)"
if [[ "$(uname -m)" == "arm64" ]] && ! echo "$FFMPEG_ARCH" | grep -q "arm64"; then
  echo "Warning: bundled ffmpeg is not arm64. On Apple Silicon, Rosetta may be required."
  echo "If you have arm64 ffmpeg locally, run ./scripts/prepare_embedded_tools.sh instead."
fi
