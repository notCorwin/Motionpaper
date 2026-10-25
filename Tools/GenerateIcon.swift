import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: GenerateIcon <source.png> <output-directory>\n", stderr)
    exit(2)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSBitmapImageRep(data: try Data(contentsOf: input)), source.hasAlpha,
      let sourceImage = source.cgImage else { throw CocoaError(.fileReadCorruptFile) }

// Normalize the selected artwork once; ignore nearly transparent edge noise.
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = -1, maxY = -1
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY,
      let cropped = sourceImage.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
else { throw CocoaError(.fileReadCorruptFile) }
let artwork = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))

@MainActor
func render(width: Int, height: Int, inset: CGFloat, template: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    let available = bounds.insetBy(dx: inset, dy: inset)
    let scale = min(available.width / artwork.size.width, available.height / artwork.size.height)
    let size = NSSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
    let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    artwork.draw(in: rect)
    if template {
        NSColor.black.setFill()
        bounds.fill(using: .sourceIn)
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let suffix = scale == 2 ? "@2x" : ""
        try render(width: pixels, height: pixels, inset: CGFloat(pixels) * 0.06)
            .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
// The menu bar uses the same silhouette as an appearance-aware template image.
let statusWidth = 80
let statusHeight = Int(ceil(CGFloat(statusWidth) * artwork.size.height / artwork.size.width))
try render(width: statusWidth, height: statusHeight, inset: 1, template: true)
    .write(to: output.appendingPathComponent("StatusIcon.png"))
