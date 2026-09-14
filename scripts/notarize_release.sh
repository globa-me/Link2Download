#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Link2Download.app"
DMG_PATH="$BUILD_DIR/Link2Download-Installer.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-Link2Download}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
export SIGNING_IDENTITY

# Fail before replacing artifacts if credentials are unavailable.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  TARGET_ARCH=universal2 "$ROOT_DIR/scripts/fetch_runtime_tools.sh"
  "$ROOT_DIR/scripts/build_app.sh"
fi

require_universal_binary() {
  local binary="$1" label="$2" archs
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
    echo "$label must be Universal 2 (arm64 + x86_64); found: ${archs:-unknown}" >&2
    exit 1
  fi
}

require_universal_binary "$APP_PATH/Contents/MacOS/Link2Download" "Link2Download"
for tool_name in yt-dlp ffmpeg ffprobe deno; do
  require_universal_binary "$APP_PATH/Contents/Resources/bin/$tool_name" "$tool_name"
done

for arch_name in arm64 x86_64; do
  arch "-$arch_name" "$APP_PATH/Contents/Resources/bin/yt-dlp" --version
  arch "-$arch_name" "$APP_PATH/Contents/Resources/bin/deno" --version
  arch "-$arch_name" "$APP_PATH/Contents/Resources/bin/ffmpeg" -version 2>&1 | sed -n '1p'
  arch "-$arch_name" "$APP_PATH/Contents/Resources/bin/ffprobe" -version 2>&1 | sed -n '1p'
done

codesign --verify --deep --strict "$APP_PATH"
signature_details="$(codesign -dvv "$APP_PATH" 2>&1)"
if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
  echo 'A Developer ID Application signature is required.' >&2
  exit 1
fi

notarize() {
  local artifact="$1" label="$2" status submission_id
  local receipt="$BUILD_DIR/notary-$label.plist"
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$receipt"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$receipt")"
  if [[ "$status" != "Accepted" ]]; then
    submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$receipt")"
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$BUILD_DIR/notary-$label-log.json"
    echo "Notarization failed: $status. See $BUILD_DIR/notary-$label-log.json" >&2
    exit 1
  fi
}

ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Link2Download-notary.zip"
notarize "$BUILD_DIR/Link2Download-notary.zip" app
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
RELEASE_DMG=1 "$ROOT_DIR/scripts/build_dmg.sh"
notarize "$DMG_PATH" dmg
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
echo "Ready for distribution: $DMG_PATH"
