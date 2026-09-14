#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YTDLP_BIN="${YTDLP_BIN:-$ROOT_DIR/Resources/bin/yt-dlp}"
FFMPEG_DIR="${FFMPEG_DIR:-$(dirname "$YTDLP_BIN")}"
DENO_BIN="${DENO_BIN:-$(dirname "$YTDLP_BIN")/deno}"
TEST_URL="${1:-https://www.youtube.com/watch?v=P8e-FfBFRTQ}"
mkdir -p "$ROOT_DIR/build"
TEST_DIR="$(mktemp -d "$ROOT_DIR/build/youtube-runtime-smoke.XXXXXX")"
mkdir -p "$TEST_DIR/home"

for tool_path in "$YTDLP_BIN" "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$DENO_BIN"; do
  if [[ ! -x "$tool_path" ]]; then
    echo "Runtime tool missing or not executable: $tool_path" >&2
    exit 1
  fi
done

# No Homebrew, shell configuration, account cookies or existing JS cache.
# Run the actual bundled program; --test limits each media stream's download.
# A separate watchdog bounds cold-start failures, including --version itself.
run_bounded() {
  "$@" &
  local command_pid=$!
  (
    sleep "${RUNTIME_TEST_TIMEOUT:-180}"
    kill -TERM "$command_pid" 2>/dev/null || exit 0
    sleep 3
    kill -KILL "$command_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  local watchdog_pid=$!
  local result=0
  wait "$command_pid" || result=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$result"
}
RUN=(/usr/bin/env -i "HOME=$TEST_DIR/home" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "LC_ALL=en_US.UTF-8")
if [[ -n "${TEST_ARCH:-}" ]]; then
  RUN+=(/usr/bin/arch "-$TEST_ARCH")
fi
run_bounded "${RUN[@]}" "$YTDLP_BIN" --version
run_bounded "${RUN[@]}" "$DENO_BIN" --version
run_bounded "${RUN[@]}" "$YTDLP_BIN" \
  --ignore-config --no-cache-dir --no-cookies-from-browser \
  --no-js-runtimes --js-runtimes "deno:$DENO_BIN" \
  --socket-timeout 20 --test --no-quiet --no-simulate --newline \
  --ffmpeg-location "$FFMPEG_DIR" \
  --retries 1 --fragment-retries 1 --extractor-retries 1 \
  -f 'bestvideo*[protocol!=sabr][format_note!*=Premium][ext=mp4]+bestaudio[protocol!=sabr][format_note!*=Premium][ext=m4a]/best[protocol!=sabr][format_note!*=Premium][ext=mp4][vcodec!=none][acodec!=none]' \
  --merge-output-format mp4 \
  --output "$TEST_DIR/%(id)s.%(ext)s" "$TEST_URL"

echo "YouTube runtime smoke test passed. Test artifact: $TEST_DIR"
