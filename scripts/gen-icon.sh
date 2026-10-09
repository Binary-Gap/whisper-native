#!/usr/bin/env bash
# Generate the app icon from scratch: draw a mic glyph on a gradient via
# CoreGraphics -> 1024px master PNG -> sips-resized iconset -> asset catalog.
# Reproducible, no external image-gen. Run: bash scripts/gen-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ASSETS="$ROOT/build-assets"
ASSET_CATALOG="$ROOT/Resources/Assets.xcassets"
APPICON_SET="$ASSET_CATALOG/AppIcon.appiconset"
# Master PNG is the committed source of truth (docs/); build-assets/ holds only
# the throwaway draw script + resize intermediates.
MASTER="$ROOT/docs/AppIcon-master-1024.png"

mkdir -p "$BUILD_ASSETS"

# --- 1. Draw the 1024x1024 master PNG via CoreGraphics ---------------------
DRAW_SWIFT="$BUILD_ASSETS/draw-icon.swift"
cat > "$DRAW_SWIFT" <<'SWIFT'
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments[1]

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no ctx") }

let s = CGFloat(size)
let rect = CGRect(x: 0, y: 0, width: s, height: s)

// Full-bleed vertical gradient background (OS applies the squircle mask).
let colorSpace = CGColorSpaceCreateDeviceRGB()
let top    = CGColor(red: 0.36, green: 0.32, blue: 0.90, alpha: 1) // indigo
let bottom = CGColor(red: 0.55, green: 0.28, blue: 0.85, alpha: 1) // violet
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [top, bottom] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: s),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

// Soft radial highlight top-center for depth.
let highlight = CGGradient(colorsSpace: colorSpace,
    colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
             CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(highlight,
    startCenter: CGPoint(x: s * 0.5, y: s * 0.72), startRadius: 0,
    endCenter: CGPoint(x: s * 0.5, y: s * 0.72), endRadius: s * 0.6,
    options: [])

// --- Microphone glyph, white, centered ---
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineCap(.round)

let cx = s * 0.5
// Capsule (mic body): rounded rect.
let capW: CGFloat = s * 0.24
let capH: CGFloat = s * 0.42
let capX = cx - capW / 2
let capY = s * 0.40
let capRect = CGRect(x: capX, y: capY, width: capW, height: capH)
let capPath = CGPath(roundedRect: capRect, cornerWidth: capW / 2, cornerHeight: capW / 2, transform: nil)
ctx.addPath(capPath)
ctx.fillPath()

// Arc (mic stand cradle): stroked semicircle under the capsule.
let arcRadius = capW * 0.95
let arcCenterY = capY + capW * 0.4
ctx.setLineWidth(s * 0.035)
ctx.addArc(center: CGPoint(x: cx, y: arcCenterY),
           radius: arcRadius, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
ctx.strokePath()

// Stem (vertical line down from arc).
let stemTop = arcCenterY - arcRadius
let stemBottom = stemTop - s * 0.09
ctx.setLineWidth(s * 0.035)
ctx.move(to: CGPoint(x: cx, y: stemTop))
ctx.addLine(to: CGPoint(x: cx, y: stemBottom))
ctx.strokePath()

// Base (horizontal foot).
let footHalf = s * 0.10
ctx.move(to: CGPoint(x: cx - footHalf, y: stemBottom))
ctx.addLine(to: CGPoint(x: cx + footHalf, y: stemBottom))
ctx.strokePath()

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
SWIFT

echo "Drawing master PNG ..."
swift "$DRAW_SWIFT" "$MASTER"

# --- 2. sips-resize into an .iconset, iconutil into .icns is skipped;
#        we build an asset catalog appiconset instead ----------------------
rm -rf "$APPICON_SET"
mkdir -p "$APPICON_SET"

# macOS asset-catalog icon sizes: idiom mac, 16/32/128/256/512 @1x + @2x.
gen() { # gen <pixels> <filename>
  sips -s format png -z "$1" "$1" "$MASTER" --out "$APPICON_SET/$2" >/dev/null
}
gen 16   icon_16.png
gen 32   icon_16@2x.png
gen 32   icon_32.png
gen 64   icon_32@2x.png
gen 128  icon_128.png
gen 256  icon_128@2x.png
gen 256  icon_256.png
gen 512  icon_256@2x.png
gen 512  icon_512.png
gen 1024 icon_512@2x.png

cat > "$APPICON_SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Icon written to $APPICON_SET (master: $MASTER)"
