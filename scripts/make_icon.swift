// Renders the Voila app icon as a PNG: apricot→lavender squircle with a progress ring and checkmark.
// Usage: swift make_icon.swift [out.png] [pixels, default 1024]. Drawn on a 1024 canvas, then scaled.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let pixels = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow + gradient body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let colors = [NSColor(srgbRed: 0.961, green: 0.620, blue: 0.424, alpha: 1).cgColor,    // #F59E6C apricot
              NSColor(srgbRed: 0.608, green: 0.541, blue: 0.961, alpha: 1).cgColor] as CFArray  // #9B8AF5 lavender
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Glass highlight
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: size / 2, y: rect.maxY), end: CGPoint(x: size / 2, y: size / 2), options: [])
ctx.restoreGState()

// Progress ring
let center = CGPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 250
ctx.setLineCap(.round)
ctx.setLineWidth(56)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
ctx.strokePath()

// Checkmark
ctx.setLineWidth(64)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: center.x - 115, y: center.y + 5))
ctx.addLine(to: CGPoint(x: center.x - 30, y: center.y - 85))
ctx.addLine(to: CGPoint(x: center.x + 125, y: center.y + 95))
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
