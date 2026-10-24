import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { _ in
            let side = CGFloat(pixels)
            let rect = NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
            NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.91, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: side * 0.2, yRadius: side * 0.2).fill()
            let symbol = NSImage(systemSymbolName: "water.waves", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: side * 0.54, weight: .medium))!
                .withSymbolConfiguration(.init(paletteColors: [.white]))!
            symbol.draw(in: NSRect(x: side * 0.19, y: side * 0.19, width: side * 0.62, height: side * 0.62))
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
