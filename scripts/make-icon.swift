// Renders the menu-bar icon: usage `swift scripts/make-icon.swift <out.tiff>`
import AppKit

let out = CommandLine.arguments[1]
let reps = [16, 32].map { size -> NSBitmapImageRep in
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let text = NSAttributedString(string: "破", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.black,
    ])
    let bounds = text.size()
    text.draw(at: NSPoint(x: (16 - bounds.width) / 2, y: (16 - bounds.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0)!
try! data.write(to: URL(fileURLWithPath: out))
