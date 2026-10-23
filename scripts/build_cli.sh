#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT_DIR/build/link2download}"
TARGET_ARCH="${TARGET_ARCH:-universal2}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-12.0}"
case "$TARGET_ARCH" in
  arm64) ARCHS=(arm64) ;;
  x86_64) ARCHS=(x86_64) ;;
  universal2) ARCHS=(arm64 x86_64) ;;
  *) echo "Unsupported TARGET_ARCH: $TARGET_ARCH" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$OUTPUT")"
TEMP_DIR="$(mktemp -d /tmp/link2download-cli-build.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
BINARIES=()
for arch in "${ARCHS[@]}"; do
  binary="$TEMP_DIR/link2download-$arch"
  xcrun swiftc -parse-as-library -O -module-name Link2DownloadCLI \
    -target "${arch}-apple-macos${MIN_MACOS_VERSION}" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$ROOT_DIR"/Control/*.swift "$ROOT_DIR"/CLI/*.swift -o "$binary"
  BINARIES+=("$binary")
done
if [[ "${#BINARIES[@]}" -eq 1 ]]; then
  cp "${BINARIES[0]}" "$OUTPUT"
else
  lipo -create "${BINARIES[@]}" -output "$OUTPUT"
fi
chmod +x "$OUTPUT"
echo "Built CLI: $OUTPUT" >&2
