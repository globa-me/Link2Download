#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-/tmp/link2download-responsive-snapshots}"
BUILD_DIR="$(mktemp -d /tmp/link2download-responsive-build.XXXXXX)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_ARCH="$(uname -m)"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

SOURCE_FILES=()
while IFS= read -r -d '' source_file; do
  SOURCE_FILES+=("$source_file")
done < <(find "$ROOT_DIR/Sources" -maxdepth 1 -name '*.swift' ! -name 'Link2DownloadApp.swift' -print0)

xcrun swiftc \
  -parse-as-library \
  -module-name Link2DownloadResponsiveSnapshots \
  -target "${TARGET_ARCH}-apple-macos12.0" \
  -sdk "$SDK_PATH" \
  -o "$BUILD_DIR/render-responsive-snapshots" \
  "${SOURCE_FILES[@]}" \
  "$ROOT_DIR/scripts/render_responsive_snapshots.swift" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -framework Security \
  -lsqlite3

"$BUILD_DIR/render-responsive-snapshots" "$OUTPUT_DIR"
