#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Link2Download"
APP_BUNDLE="$APP_NAME.app"
APP_PATH="$BUILD_DIR/$APP_BUNDLE"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-12.0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
APP_VERSION="${APP_VERSION:-1.4.1}"
APP_BUILD="${APP_BUILD:-$(date +%d%m%y)}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"

case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported target architecture: $TARGET_ARCH"
    echo "Use TARGET_ARCH=arm64 or TARGET_ARCH=x86_64."
    exit 1
    ;;
esac

APP_BIN="$BUILD_DIR/${APP_NAME}-${TARGET_ARCH}"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$MODULE_CACHE_DIR"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

swiftc \
  -parse-as-library \
  -module-name "$APP_NAME" \
  -target "${TARGET_ARCH}-apple-macos${MIN_MACOS_VERSION}" \
  -sdk "$SDK_PATH" \
  -o "$APP_BIN" \
  "$ROOT_DIR"/Sources/*.swift \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -framework Security \
  -lsqlite3

mv "$APP_BIN" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -d "$ROOT_DIR/Resources/bin" ]]; then
  if [[ -x "$ROOT_DIR/Resources/bin/ffmpeg" ]]; then
    FFMPEG_FILE_INFO="$(file "$ROOT_DIR/Resources/bin/ffmpeg" 2>/dev/null || true)"
    if ! echo "$FFMPEG_FILE_INFO" | grep -q "$TARGET_ARCH"; then
      echo "Error: Resources/bin/ffmpeg does not support $TARGET_ARCH, which is the app target."
      echo "Run ./scripts/fetch_runtime_tools.sh on this Mac and rebuild."
      exit 1
    fi
  fi

  if [[ -x "$ROOT_DIR/Resources/bin/ffprobe" ]]; then
    FFPROBE_FILE_INFO="$(file "$ROOT_DIR/Resources/bin/ffprobe" 2>/dev/null || true)"
    if ! echo "$FFPROBE_FILE_INFO" | grep -q "$TARGET_ARCH"; then
      echo "Error: Resources/bin/ffprobe does not support $TARGET_ARCH, which is the app target."
      echo "Run ./scripts/fetch_runtime_tools.sh on this Mac and rebuild."
      exit 1
    fi
  fi

  mkdir -p "$RESOURCES_DIR/bin"
  cp -R "$ROOT_DIR/Resources/bin/." "$RESOURCES_DIR/bin/"
  if compgen -G "$RESOURCES_DIR/bin/*" > /dev/null; then
    chmod +x "$RESOURCES_DIR/bin"/* || true
  fi
fi

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Link2Download</string>
    <key>CFBundleExecutable</key>
    <string>Link2Download</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.gzakharov.link2download</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Link2Download</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi

echo "Built app: $APP_PATH"
