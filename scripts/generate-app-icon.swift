import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = root.appendingPathComponent("Resources", isDirectory: true)
let sourceURL = resourcesURL.appendingPathComponent("AppIconSource-WhiteSatinLoop.png")
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let previewURL = resourcesURL.appendingPathComponent("AppIcon-1024.png")
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw NSError(
        domain: "AuralIcon",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing icon source: \(sourceURL.path)"]
    )
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIconDesign() {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor.clear.setFill()
    canvas.fill()

    NSGraphicsContext.saveGraphicsState()
    rounded(canvas.insetBy(dx: 1, dy: 1), radius: 210).addClip()
    sourceImage.draw(
        in: canvas,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
}

func renderPNG(size: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "AuralIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    drawIconDesign()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AuralIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG"])
    }
    try data.write(to: url)
}

let files: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, filename) in files {
    try renderPNG(size: size, to: iconsetURL.appendingPathComponent(filename))
}
try renderPNG(size: 1024, to: previewURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "AuralIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(icnsURL.path)
