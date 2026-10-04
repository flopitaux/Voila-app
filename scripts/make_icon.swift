// Renders the Voila app icon (1024px PNG): dusty blue→sage squircle with a progress ring and checkmark.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

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
let colors = [NSColor(red: 0.42, green: 0.55, blue: 0.70, alpha: 1).cgColor,
              NSColor(red: 0.45, green: 0.65, blue: 0.62, alpha: 1).cgColor] as CFArray
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

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
