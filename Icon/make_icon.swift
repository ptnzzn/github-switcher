// Draws the app icon at 1024×1024: Big Sur–style rounded square, dark GitHub
// gradient, two-arrow "switch" ring around a person glyph.
// Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Icon body sits on the standard 824pt grid with a soft drop shadow.
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset + 8, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.23, blue: 0.27, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1),
])!.draw(in: shape, angle: -90)

// Thin top highlight for depth.
ctx.saveGState()
shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), .clear])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
ctx.restoreGState()

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

func drawCentered(_ s: NSImage, dy: CGFloat = 0) {
    let r = NSRect(x: (size - s.size.width) / 2, y: (size - s.size.height) / 2 + dy,
                   width: s.size.width, height: s.size.height)
    s.draw(in: r)
}

let accent = NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1) // GitHub green
drawCentered(symbol("arrow.triangle.2.circlepath", pointSize: 470, weight: .semibold, color: accent))
drawCentered(symbol("person.fill", pointSize: 230, weight: .medium, color: .white), dy: 4)

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
