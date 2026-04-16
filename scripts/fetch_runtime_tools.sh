#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT_DIR/Resources/bin"
TMP_DIR="$ROOT_DIR/build/runtime-download"
HOST_ARCH="$(uname -m)"

mkdir -p "$BIN_DIR" "$TMP_DIR"

echo "Downloading yt-dlp (official release binary)..."
curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$BIN_DIR/yt-dlp"
chmod +x "$BIN_DIR/yt-dlp"

FFMPEG_ZIP="$TMP_DIR/ffmpeg.zip"
FFPROBE_ZIP="$TMP_DIR/ffprobe.zip"
FFMPEG_SHA256=""
FFPROBE_SHA256=""

if [[ "$HOST_ARCH" == "arm64" ]]; then
  echo "Downloading ffmpeg + ffprobe (Apple Silicon static builds)..."
  curl -L "https://www.osxexperts.net/ffmpeg80arm.zip" -o "$FFMPEG_ZIP"
  curl -L "https://www.osxexperts.net/ffprobe80arm.zip" -o "$FFPROBE_ZIP"
  FFMPEG_SHA256="77d2c853f431318d55ec02676d9b2f185ebfdddb9f7677a251fbe453affe025a"
  FFPROBE_SHA256="babf170e86bd6b0b2fefee5fa56f57721b0acb98ad2794b095d8030b02857dfe"
else
  echo "Downloading ffmpeg + ffprobe (Intel static builds)..."
  curl -L "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o "$FFMPEG_ZIP"
  curl -L "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip" -o "$FFPROBE_ZIP"
fi

if [[ -n "$FFMPEG_SHA256" ]]; then
  ACTUAL="$(shasum -a 256 "$FFMPEG_ZIP" | awk '{print $1}')"
  if [[ "$ACTUAL" != "$FFMPEG_SHA256" ]]; then
    echo "Warning: checksum mismatch for ffmpeg archive"
    echo "Expected: $FFMPEG_SHA256"
    echo "Actual:   $ACTUAL"
    if [[ "${STRICT_CHECKSUM:-0}" == "1" ]]; then
      exit 1
    fi
  fi
fi

if [[ -n "$FFPROBE_SHA256" ]]; then
  ACTUAL="$(shasum -a 256 "$FFPROBE_ZIP" | awk '{print $1}')"
  if [[ "$ACTUAL" != "$FFPROBE_SHA256" ]]; then
    echo "Warning: checksum mismatch for ffprobe archive"
    echo "Expected: $FFPROBE_SHA256"
    echo "Actual:   $ACTUAL"
    if [[ "${STRICT_CHECKSUM:-0}" == "1" ]]; then
      exit 1
    fi
  fi
fi

unzip -o "$FFMPEG_ZIP" -d "$TMP_DIR" >/dev/null
unzip -o "$FFPROBE_ZIP" -d "$TMP_DIR" >/dev/null

cp "$TMP_DIR/ffmpeg" "$BIN_DIR/ffmpeg"
cp "$TMP_DIR/ffprobe" "$BIN_DIR/ffprobe"
chmod +x "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe" >/dev/null 2>&1 || true
fi

echo "Runtime tools are ready in: $BIN_DIR"

FFMPEG_ARCH="$(file "$BIN_DIR/ffmpeg" 2>/dev/null || true)"
FFPROBE_ARCH="$(file "$BIN_DIR/ffprobe" 2>/dev/null || true)"
echo "$FFMPEG_ARCH"
echo "$FFPROBE_ARCH"

if [[ "$HOST_ARCH" == "arm64" ]] && ! echo "$FFMPEG_ARCH" | grep -q "arm64"; then
  echo "Warning: bundled ffmpeg is still not arm64."
  echo "Use local arm64 binaries via ./scripts/prepare_embedded_tools.sh if needed."
fi
