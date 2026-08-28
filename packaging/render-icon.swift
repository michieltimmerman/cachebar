// Renders the app icon source PNG: 🔥 on a dark rounded square, drawn at an
// explicit pixel size so a retina display can't double it.
// Usage: swift render-icon.swift <out.png> [pixels]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let px = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
// Big Sur-style margins: the visible squircle is ~80% of the canvas.
let inset = size * 0.10
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.225
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1),
])!.draw(in: squircle, angle: -90)

let flame = "🔥" as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.52)]
let bounds = flame.size(withAttributes: attrs)
flame.draw(at: NSPoint(x: (size - bounds.width) / 2,
                       y: (size - bounds.height) / 2),
           withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(px)x\(px))")
