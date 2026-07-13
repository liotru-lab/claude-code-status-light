#!/usr/bin/env swift
//
// Generates the CC Status Light app icon: a circular dot split diagonally into
// three bands — red (top-left), yellow (middle), green (bottom-right) — matching
// the app's status colours. Renders a PNG per macOS icon pixel size.
//
// Usage: swift make-icon.swift <output-dir>
// Produces icon_<px>.png for px in 16 32 64 128 256 512 1024.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// System colours (match SwiftUI .red / .yellow / .green closely).
let red    = (r: 255.0/255, g:  59.0/255, b:  48.0/255)
let yellow = (r: 255.0/255, g: 204.0/255, b:   0.0/255)
let green  = (r:  52.0/255, g: 199.0/255, b:  89.0/255)

func render(_ px: Int) -> CGImage {
    let S = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, y down, so the geometry reads naturally.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Circular dot with a small inset.
    let inset = S * 0.045
    ctx.addEllipse(in: CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset))
    ctx.clip()

    // Split by lines x + y = (S - w) and x + y = (S + w), perpendicular to the
    // top-left→bottom-right diagonal. `w` is the middle (yellow) band's diagonal
    // half-width; < S/3 makes the yellow band slightly smaller than equal thirds.
    let w = S * 0.20
    let lower = S - w
    func fill(_ pts: [(CGFloat, CGFloat)], _ c: (r: Double, g: Double, b: Double)) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
        ctx.closePath()
        ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        ctx.fillPath()
    }
    fill([(0, 0), (lower, 0), (0, lower)], red)                                      // top-left
    fill([(lower, 0), (S, 0), (S, w), (w, S), (0, S), (0, lower)], yellow)          // middle
    fill([(S, w), (S, S), (w, S)], green)                                           // bottom-right

    return ctx.makeImage()!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let img = render(px)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(px).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    if CGImageDestinationFinalize(dest) {
        print("wrote \(url.lastPathComponent)")
    } else {
        FileHandle.standardError.write(Data("failed \(px)\n".utf8))
    }
}
