#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$ROOT_DIR/build"
APP_VERSION="${APP_VERSION:-1.4.4}"
APP_BUILD="${APP_BUILD:-$(date +%d%m%y)}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"

require_thin_binary() {
  local binary="$1" expected_arch="$2" label="$3" archs
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  if [[ "$archs" != "$expected_arch" ]]; then
    echo "$label must contain only $expected_arch; found: ${archs:-unknown}" >&2
    exit 1
  fi
}

require_supported_arch() {
  local binary="$1" expected_arch="$2" label="$3" archs
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  if [[ " $archs " != *" $expected_arch "* ]]; then
    echo "$label must support $expected_arch; found: ${archs:-unknown}" >&2
    exit 1
  fi
}

build_variant() {
  local arch_name="$1" artifact_label="$2"
  local variant_dir="$BUILD_ROOT/macos-$arch_name"
  local runtime_dir="$BUILD_ROOT/runtime-$arch_name"
  local app_path="$variant_dir/Link2Download.app"
  local archive_path="$BUILD_ROOT/Link2Download-$APP_VERSION-macOS-$artifact_label.zip"
  local signature_details

  echo "Building Link2Download $APP_VERSION for $arch_name..."
  RUNTIME_BIN_DIR="$runtime_dir" TARGET_ARCH="$arch_name" \
    "$ROOT_DIR/scripts/fetch_runtime_tools.sh"

  BUILD_DIR="$variant_dir" \
    RUNTIME_BIN_DIR="$runtime_dir" \
    TARGET_ARCH="$arch_name" \
    APP_VERSION="$APP_VERSION" \
    APP_BUILD="$APP_BUILD" \
    SIGNING_IDENTITY="$SIGNING_IDENTITY" \
    "$ROOT_DIR/scripts/build_app.sh"

  require_thin_binary "$app_path/Contents/MacOS/Link2Download" "$arch_name" "Link2Download"
  require_supported_arch "$app_path/Contents/Resources/bin/yt-dlp" "$arch_name" "yt-dlp"
  codesign --verify --strict "$app_path/Contents/Resources/bin/yt-dlp"
  for tool_name in ffmpeg ffprobe deno; do
    require_thin_binary "$app_path/Contents/Resources/bin/$tool_name" "$arch_name" "$tool_name"
    codesign --verify --strict "$app_path/Contents/Resources/bin/$tool_name"
  done

  codesign --verify --deep --strict "$app_path"
  signature_details="$(codesign -dvv "$app_path" 2>&1)"
  if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
    echo "Developer ID Application signature is missing from $app_path" >&2
    exit 1
  fi

  arch "-$arch_name" "$app_path/Contents/Resources/bin/yt-dlp" --version
  arch "-$arch_name" "$app_path/Contents/Resources/bin/deno" --version
  arch "-$arch_name" "$app_path/Contents/Resources/bin/ffmpeg" -version 2>&1 | sed -n '1p'
  arch "-$arch_name" "$app_path/Contents/Resources/bin/ffprobe" -version 2>&1 | sed -n '1p'

  rm -f "$archive_path" "$archive_path.sha256"
  ditto -c -k --keepParent "$app_path" "$archive_path"
  shasum -a 256 "$archive_path" > "$archive_path.sha256"

  echo "Signed app: $app_path"
  echo "Archive: $archive_path"
}

mkdir -p "$BUILD_ROOT"
case "${MACOS_VARIANTS:-all}" in
  all)
    build_variant arm64 Apple-Silicon
    build_variant x86_64 Intel
    ;;
  arm64)
    build_variant arm64 Apple-Silicon
    ;;
  x86_64)
    build_variant x86_64 Intel
    ;;
  *)
    echo "MACOS_VARIANTS must be all, arm64, or x86_64." >&2
    exit 1
    ;;
esac

echo "Requested architecture-specific signed variants are ready."
