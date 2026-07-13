// Generates a simple SK Voice app icon: rounded gradient square with a mic glyph.
// Usage: swift icongen.swift <output.png> <size>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let size = Int(arguments[2]) else {
    print("usage: icongen.swift <output.png> <size>")
    exit(1)
}
let outputPath = arguments[1]
let dimension = CGFloat(size)

let image = NSImage(size: NSSize(width: dimension, height: dimension))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
let rounded = NSBezierPath(roundedRect: rect.insetBy(dx: dimension * 0.05,
                                                     dy: dimension * 0.05),
                           xRadius: dimension * 0.2, yRadius: dimension * 0.2)
// Deep indigo → teal diagonal, premium dark glass feel.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.28, green: 0.26, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.35, blue: 0.38, alpha: 1),
])!
gradient.draw(in: rounded, angle: -55)

// Subtle inner highlight along the top edge.
if let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.0),
]) {
    let top = NSBezierPath(roundedRect: NSRect(
        x: dimension * 0.05, y: dimension * 0.55,
        width: dimension * 0.9, height: dimension * 0.4),
        xRadius: dimension * 0.2, yRadius: dimension * 0.2)
    highlight.draw(in: top, angle: -90)
}

let config = NSImage.SymbolConfiguration(pointSize: dimension * 0.5, weight: .light)
if let mic = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: mic.size)
    tinted.lockFocus()
    NSColor.white.set()
    let micRect = NSRect(origin: .zero, size: mic.size)
    mic.draw(in: micRect)
    micRect.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let glyphSize = NSSize(width: dimension * 0.5,
                           height: dimension * 0.5 * mic.size.height / mic.size.width)
    let origin = NSPoint(x: (dimension - glyphSize.width) / 2,
                         y: (dimension - glyphSize.height) / 2)
    tinted.draw(in: NSRect(origin: origin, size: glyphSize))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    print("icon render failed")
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
