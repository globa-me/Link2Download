#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/link2download-retry-test.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
SOURCE_FILES=()
while IFS= read -r -d '' source_file; do
  SOURCE_FILES+=("$source_file")
done < <(find "$ROOT_DIR/Sources" -maxdepth 1 -name '*.swift' ! -name 'Link2DownloadApp.swift' -print0)
xcrun swiftc -parse-as-library -module-name Link2DownloadRetryTests \
  -target "$(uname -m)-apple-macos12.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -o "$BUILD_DIR/retry-tests" "${SOURCE_FILES[@]}" "$ROOT_DIR/scripts/test_retry_history.swift" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -framework Security -lsqlite3
"$BUILD_DIR/retry-tests"
