#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YTDLP_BIN="${YTDLP_BIN:-$ROOT_DIR/Resources/bin/yt-dlp}"
FFMPEG_DIR="${FFMPEG_DIR:-$ROOT_DIR/Resources/bin}"
TEST_URL="${1:-https://www.youtube.com/watch?v=3WbXyUolFA0}"
TEST_DIR="$(mktemp -d "$ROOT_DIR/build/youtube-runtime-smoke.XXXXXX")"

if [[ ! -x "$YTDLP_BIN" ]]; then
  echo "yt-dlp is missing or not executable: $YTDLP_BIN"
  exit 1
fi

echo "Testing yt-dlp $("$YTDLP_BIN" --version) with stable YouTube formats..."
"$YTDLP_BIN" \
  --ignore-config \
  --test \
  --no-warnings \
  --extractor-args "youtube:player_client=tv_embedded" \
  --ffmpeg-location "$FFMPEG_DIR" \
  --retries 5 \
  --fragment-retries 5 \
  --extractor-retries 3 \
  -f 'bestvideo*[protocol!=sabr][format_note!*=Premium][ext=mp4]+bestaudio[protocol!=sabr][format_note!*=Premium][ext=m4a]/best[protocol!=sabr][format_note!*=Premium][ext=mp4][vcodec!=none][acodec!=none]' \
  --merge-output-format mp4 \
  --output "$TEST_DIR/%(id)s.%(ext)s" \
  "$TEST_URL"

echo "YouTube runtime smoke test passed. Test artifact: $TEST_DIR"
