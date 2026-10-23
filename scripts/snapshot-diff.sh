#!/usr/bin/env bash
# Compares two UISnapshots folders: each PNG with the same name, ignoring the toolbar search icon, whose
# vibrancy AppKit picks at random per window (Large Files, Space Lens). Masked: x from right edge-36 to edge-16,
# y 14–38 from the top (icon at x 686–701, y 18–34 in a 720 px shot), on every PNG. A channel differing by at most
# SNAPSHOT_TOLERANCE levels (default 2) counts as equal: busy Macs showed 1-level shifts on Uninstaller icons on a busy Mac;
# 3 checkbox pixels in the 8 dark Smart Scan shots differ by 2 levels per test run (same in every shot of one run,
# so render noise of the process, not timing).
# Prints changed PNGs with their differing pixel count, PNGs only in one folder; exit 1 if any, 2 on bad usage.
# Usage: scripts/snapshot-diff.sh <folder A> <folder B>
set -euo pipefail

[[ $# == 2 && -d "$1" && -d "$2" ]] || { echo "Usage: $0 <folder A> <folder B>" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/diff.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

let tolerance = Int(ProcessInfo.processInfo.environment["SNAPSHOT_TOLERANCE"] ?? "2") ?? 2

/// RGBA8 pixels in sRGB, so both sides are compared in the same space whatever the PNG stores.
func pixels(_ path: String) -> (w: Int, h: Int, data: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let (w, h) = (img.width, img.height)
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ok = data.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, data) : nil
}

func masked(_ x: Int, _ y: Int, _ w: Int) -> Bool { x >= w - 36 && x < w - 16 && y >= 14 && y < 38 }

/// Differing pixels outside the mask, or nil when the sizes differ / a file is unreadable.
func diff(_ a: String, _ b: String) -> Int? {
    guard let p = pixels(a), let q = pixels(b), p.w == q.w, p.h == q.h else { return nil }
    var count = 0
    for y in 0..<p.h { for x in 0..<p.w where !masked(x, y, p.w) {
        let i = (y * p.w + x) * 4 // CGContext rows start at the top in memory
        if (0..<4).contains(where: { abs(Int(p.data[i + $0]) - Int(q.data[i + $0])) > tolerance }) { count += 1 }
    } }
    return count
}

let (dirA, dirB) = (CommandLine.arguments[1], CommandLine.arguments[2])
let fm = FileManager.default
func pngs(_ dir: String) -> Set<String> { Set(((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".png") }) }
let (a, b) = (pngs(dirA), pngs(dirB))
var bad = 0
for name in a.intersection(b).sorted() {
    switch diff("\(dirA)/\(name)", "\(dirB)/\(name)") {
    case 0?: break
    case let n?: print("DIFF \(name): \(n) px"); bad += 1
    case nil: print("DIFF \(name): size differs or unreadable"); bad += 1
    }
}
for name in a.subtracting(b).sorted() { print("ONLY A \(name)"); bad += 1 }
for name in b.subtracting(a).sorted() { print("ONLY B \(name)"); bad += 1 }
print("\(a.intersection(b).count) compared, \(bad) different")

// Self-check of the mask edges on a 720 px shot (icon x 686–701, y 18–34).
precondition(masked(686, 18, 720) && masked(701, 34, 720) && !masked(683, 18, 720) && !masked(690, 40, 720))
exit(bad == 0 ? 0 : 1)
SWIFT
xcrun swiftc -O -o "$TMP/diff" "$TMP/diff.swift"
"$TMP/diff" "$1" "$2"
