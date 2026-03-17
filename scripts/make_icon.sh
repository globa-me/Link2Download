#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ICON_SOURCE:-}"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
DEST="$ROOT_DIR/Resources/AppIcon.icns"
PREPARED_PNG="$ROOT_DIR/Resources/AppIcon.png"
MODULE_CACHE_DIR="$ROOT_DIR/build/module-cache"

mkdir -p "$MODULE_CACHE_DIR"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

if [[ -z "$SRC" ]]; then
  if [[ -f "$ROOT_DIR/Link2Download.png" ]]; then
    SRC="$ROOT_DIR/Link2Download.png"
  elif [[ -f "$PREPARED_PNG" ]]; then
    SRC="$PREPARED_PNG"
  fi
fi

if [[ ! -f "$SRC" ]]; then
  echo "Source icon not found."
  echo "Expected one of:"
  echo "  1) ICON_SOURCE env var"
  echo "  2) $ROOT_DIR/Link2Download.png"
  echo "  3) $PREPARED_PNG"
  exit 1
fi

swift - "$SRC" "$PREPARED_PNG" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let sourcePath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard
    let sourceImage = NSImage(contentsOfFile: sourcePath),
    let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("Failed to load source icon: \(sourcePath)\n", stderr)
    exit(1)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var srcBytes = [UInt8](repeating: 0, count: height * bytesPerRow)
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let srcContext = CGContext(
    data: &srcBytes,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create source bitmap context\n", stderr)
    exit(1)
}

srcContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

@inline(__always)
func pixelOffset(_ x: Int, _ y: Int) -> Int {
    (y * bytesPerRow) + (x * bytesPerPixel)
}

func clamp(_ value: Int, min low: Int, max high: Int) -> Int {
    Swift.min(Swift.max(value, low), high)
}

var minX = width
var minY = height
var maxX = 0
var maxY = 0
let alphaThreshold: UInt8 = 8

for y in 0..<height {
    for x in 0..<width {
        let o = pixelOffset(x, y)
        if srcBytes[o + 3] >= alphaThreshold {
            minX = Swift.min(minX, x)
            minY = Swift.min(minY, y)
            maxX = Swift.max(maxX, x)
            maxY = Swift.max(maxY, y)
        }
    }
}

let cropRect: CGRect
if minX < maxX, minY < maxY {
    let pad = max(24, min(width, height) / 60)
    let x = clamp(minX - pad, min: 0, max: width - 1)
    let y = clamp(minY - pad, min: 0, max: height - 1)
    let w = clamp((maxX - minX) + (2 * pad), min: 1, max: width - x)
    let h = clamp((maxY - minY) + (2 * pad), min: 1, max: height - y)
    cropRect = CGRect(x: x, y: y, width: w, height: h)
} else {
    cropRect = CGRect(x: 0, y: 0, width: width, height: height)
}

let subject = cgImage.cropping(to: cropRect) ?? cgImage

let outSize = 1024
let outBytesPerRow = outSize * bytesPerPixel
var outBytes = [UInt8](repeating: 0, count: outSize * outBytesPerRow)

guard let outContext = CGContext(
    data: &outBytes,
    width: outSize,
    height: outSize,
    bitsPerComponent: 8,
    bytesPerRow: outBytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create output bitmap context\n", stderr)
    exit(1)
}

outContext.clear(CGRect(x: 0, y: 0, width: outSize, height: outSize))

let insetRect = CGRect(x: 68, y: 68, width: outSize - 136, height: outSize - 136)
let subjectWidth = CGFloat(subject.width)
let subjectHeight = CGFloat(subject.height)
let scale = min(insetRect.width / subjectWidth, insetRect.height / subjectHeight)
let drawWidth = subjectWidth * scale
let drawHeight = subjectHeight * scale
let drawRect = CGRect(
    x: insetRect.midX - (drawWidth / 2.0),
    y: insetRect.midY - (drawHeight / 2.0),
    width: drawWidth,
    height: drawHeight
)

outContext.draw(subject, in: drawRect)

guard let outImage = outContext.makeImage() else {
    fputs("Failed to render output image\n", stderr)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: outImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode output PNG\n", stderr)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outPath), options: .atomic)
print("Prepared icon PNG: \(outPath)")
SWIFT

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$PREPARED_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "$PREPARED_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$PREPARED_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "$PREPARED_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$PREPARED_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "$PREPARED_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$PREPARED_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "$PREPARED_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$PREPARED_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$PREPARED_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$DEST"
rm -rf "$ICONSET_DIR"

echo "Created icon: $DEST"
