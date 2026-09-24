#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/link2download-error-test.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun swiftc -parse-as-library -o "$BUILD_DIR/error-tests" \
  "$ROOT_DIR/Sources/ProcessErrorMessage.swift" \
  "$ROOT_DIR/scripts/test_process_error_message.swift"
"$BUILD_DIR/error-tests"
