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
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.35, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.18, alpha: 1),
])!
gradient.draw(in: rounded, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: dimension * 0.5, weight: .medium)
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
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
