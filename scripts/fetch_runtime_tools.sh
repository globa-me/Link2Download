#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${RUNTIME_BIN_DIR:-$ROOT_DIR/Resources/bin}"
TMP_DIR="$ROOT_DIR/build/runtime-download"
TARGET_ARCH="${TARGET_ARCH:-universal2}"
YTDLP_VERSION="2026.08.19"
YTDLP_SHA256="07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8"
DENO_VERSION="2.7.7"
INTEL_FFMPEG_VERSION="9.0.1"

case "$TARGET_ARCH" in
  arm64) TARGET_ARCHS=(arm64) ;;
  x86_64) TARGET_ARCHS=(x86_64) ;;
  universal2) TARGET_ARCHS=(arm64 x86_64) ;;
  *)
    echo "Unsupported target architecture: $TARGET_ARCH"
    echo "Use TARGET_ARCH=universal2, TARGET_ARCH=arm64, or TARGET_ARCH=x86_64."
    exit 1
    ;;
esac

rm -rf "$TMP_DIR"
mkdir -p "$BIN_DIR" "$TMP_DIR"

download() {
  local url="$1" destination="$2"
  curl --fail --location --retry 3 --retry-delay 2 "$url" -o "$destination"
}

binary_has_arch() {
  local binary="$1" required_arch="$2" archs
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  [[ " $archs " == *" $required_arch "* ]]
}

verify_checksum() {
  local file_path="$1" expected="$2" label="$3" actual
  actual="$(shasum -a 256 "$file_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Error: checksum verification failed for $label"
    echo "Expected: $expected"
    echo "Actual:   $actual"
    exit 1
  fi
}

# The one-directory distribution keeps Python libraries at stable paths. The
# one-file bootloader otherwise extracts and revalidates them on every launch.
echo "Downloading yt-dlp $YTDLP_VERSION (official Universal 2 onedir archive)..."
download "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos.zip" "$TMP_DIR/yt-dlp_macos.zip"
verify_checksum "$TMP_DIR/yt-dlp_macos.zip" "$YTDLP_SHA256" "yt-dlp_macos.zip $YTDLP_VERSION"
mkdir -p "$TMP_DIR/ytdlp"
ditto -x -k "$TMP_DIR/yt-dlp_macos.zip" "$TMP_DIR/ytdlp"
rm -rf "$BIN_DIR/_internal"
ditto "$TMP_DIR/ytdlp/_internal" "$BIN_DIR/_internal"
# Upstream ZIP materializes framework symlinks as duplicate files/directories.
# Restore Apple's canonical versioned layout before signing the nested framework.
python_framework="$BIN_DIR/_internal/Python.framework"
rm -rf "$python_framework/Python" "$python_framework/Resources" "$python_framework/Versions/Current"
ln -s 3.14 "$python_framework/Versions/Current"
ln -s Versions/Current/Python "$python_framework/Python"
ln -s Versions/Current/Resources "$python_framework/Resources"
rm "$BIN_DIR/_internal/Python"
ln -s Python.framework/Versions/Current/Python "$BIN_DIR/_internal/Python"
cp "$TMP_DIR/ytdlp/yt-dlp_macos" "$BIN_DIR/yt-dlp"
chmod +x "$BIN_DIR/yt-dlp"

download_deno() {
  local arch="$1" upstream_arch expected arch_dir
  arch_dir="$TMP_DIR/$arch"
  case "$arch" in
    arm64)
      upstream_arch=aarch64
      expected="5f0ef47e706ecdae5e6248e33bf367340b1d86f87886f60419fe7450f6ffc39a"
      ;;
    x86_64)
      upstream_arch=x86_64
      expected="2ca88d69c369a2757f17fce7c21d979f04cf56a6990d1f3858bd80b0487d0b74"
      ;;
  esac
  mkdir -p "$arch_dir"
  download "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-$upstream_arch-apple-darwin.zip" "$arch_dir/deno.zip"
  verify_checksum "$arch_dir/deno.zip" "$expected" "Deno $DENO_VERSION $arch"
  unzip -j -o "$arch_dir/deno.zip" deno -d "$arch_dir" >/dev/null
  chmod +x "$arch_dir/deno"
}

download_arm64_tools() {
  local arch_dir="$TMP_DIR/arm64"
  local ffmpeg_zip="$arch_dir/ffmpeg.zip"
  local ffprobe_zip="$arch_dir/ffprobe.zip"
  local expected_ffmpeg="0d4efcaf6a098430a708e0af694a84792938921fa126162787ae98c6151d7a95"
  local expected_ffprobe="b46eb342707ec0d31d3e8337bb56831e59c9e20918f414fd7a9d65a32fcb348f"

  mkdir -p "$arch_dir"
  echo "Downloading ffmpeg + ffprobe (Apple Silicon static builds)..."
  download "https://www.osxexperts.net/ffmpeg80arm.zip" "$ffmpeg_zip"
  download "https://www.osxexperts.net/ffprobe80arm.zip" "$ffprobe_zip"

  verify_checksum "$ffmpeg_zip" "$expected_ffmpeg" "ARM64 ffmpeg 8.0 archive"
  verify_checksum "$ffprobe_zip" "$expected_ffprobe" "ARM64 ffprobe 8.0 archive"

  unzip -j -o "$ffmpeg_zip" ffmpeg -d "$arch_dir" >/dev/null
  unzip -j -o "$ffprobe_zip" ffprobe -d "$arch_dir" >/dev/null
  chmod +x "$arch_dir/ffmpeg" "$arch_dir/ffprobe"
}

download_x86_64_tools() {
  local arch_dir="$TMP_DIR/x86_64"
  local expected_ffmpeg="8a8c9e549983409fe6604b9aa665648b7a5def9407fe814c39c8b2ea7f64a48f"
  local expected_ffprobe="d13f35db03456b7f65b7edb6437c86e23810fbfe91795e571f5b77211343b4f1"
  mkdir -p "$arch_dir"
  echo "Downloading ffmpeg + ffprobe $INTEL_FFMPEG_VERSION (Intel static builds)..."
  download "https://evermeet.cx/ffmpeg/ffmpeg-$INTEL_FFMPEG_VERSION.zip" "$arch_dir/ffmpeg.zip"
  download "https://evermeet.cx/ffmpeg/ffprobe-$INTEL_FFMPEG_VERSION.zip" "$arch_dir/ffprobe.zip"
  verify_checksum "$arch_dir/ffmpeg.zip" "$expected_ffmpeg" "Intel ffmpeg $INTEL_FFMPEG_VERSION archive"
  verify_checksum "$arch_dir/ffprobe.zip" "$expected_ffprobe" "Intel ffprobe $INTEL_FFMPEG_VERSION archive"
  unzip -j -o "$arch_dir/ffmpeg.zip" ffmpeg -d "$arch_dir" >/dev/null
  unzip -j -o "$arch_dir/ffprobe.zip" ffprobe -d "$arch_dir" >/dev/null
  chmod +x "$arch_dir/ffmpeg" "$arch_dir/ffprobe"
}

for arch in "${TARGET_ARCHS[@]}"; do
  "download_${arch}_tools"
  download_deno "$arch"
  for tool_name in ffmpeg ffprobe deno; do
    if ! binary_has_arch "$TMP_DIR/$arch/$tool_name" "$arch"; then
      echo "Error: downloaded $tool_name does not contain the required $arch architecture."
      exit 1
    fi
  done
done

for tool_name in ffmpeg ffprobe deno; do
  if [[ "${#TARGET_ARCHS[@]}" -eq 1 ]]; then
    cp "$TMP_DIR/${TARGET_ARCHS[0]}/$tool_name" "$BIN_DIR/$tool_name"
  else
    lipo -create \
      "$TMP_DIR/arm64/$tool_name" \
      "$TMP_DIR/x86_64/$tool_name" \
      -output "$BIN_DIR/$tool_name"
  fi
  chmod +x "$BIN_DIR/$tool_name"
done

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$BIN_DIR/yt-dlp" "$BIN_DIR/_internal" "$BIN_DIR/deno" "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe" >/dev/null 2>&1 || true
fi

for tool_name in yt-dlp ffmpeg ffprobe deno; do
  for arch in "${TARGET_ARCHS[@]}"; do
    if ! binary_has_arch "$BIN_DIR/$tool_name" "$arch"; then
      echo "Error: $tool_name is missing the required $arch architecture."
      exit 1
    fi
  done
  echo "$tool_name architectures: $(lipo -archs "$BIN_DIR/$tool_name")"
done

echo "Runtime tools are ready in: $BIN_DIR"
