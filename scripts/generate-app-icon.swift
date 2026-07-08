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

func clamp(_ value: CGFloat, _ lower: CGFloat = 0, _ upper: CGFloat = 1) -> CGFloat {
    min(max(value, lower), upper)
}

func makeBitmapRep(size: Int) throws -> NSBitmapImageRep {
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
    return rep
}

func renderSourceAtBaseSize() throws -> NSBitmapImageRep {
    let rep = try makeBitmapRep(size: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func makeExtractedLogoImage() throws -> NSImage {
    let sourceRep = try renderSourceAtBaseSize()
    let logoRep = try makeBitmapRep(size: 1024)
    guard let sourceData = sourceRep.bitmapData,
          let logoData = logoRep.bitmapData else {
        throw NSError(domain: "AuralIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to access bitmap data"])
    }
    let sourceBytesPerRow = sourceRep.bytesPerRow
    let logoBytesPerRow = logoRep.bytesPerRow
    let sourceSamples = sourceRep.samplesPerPixel
    let logoSamples = logoRep.samplesPerPixel

    func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamp(value) * 255)
    }

    for y in 0..<1024 {
        for x in 0..<1024 {
            let sourceOffset = y * sourceBytesPerRow + x * sourceSamples
            let logoOffset = y * logoBytesPerRow + x * logoSamples
            let red = CGFloat(sourceData[sourceOffset]) / 255
            let green = CGFloat(sourceData[sourceOffset + 1]) / 255
            let blue = CGFloat(sourceData[sourceOffset + 2]) / 255
            let blueDominance = blue - ((red + green) * 0.5)
            let chroma = max(red, green, blue) - min(red, green, blue)
            let alpha = clamp((blueDominance - 0.045) / 0.18) * clamp((chroma - 0.04) / 0.18)

            guard alpha > 0.015 else {
                logoData[logoOffset] = 0
                logoData[logoOffset + 1] = 0
                logoData[logoOffset + 2] = 0
                logoData[logoOffset + 3] = 0
                continue
            }

            logoData[logoOffset] = byte(red)
            logoData[logoOffset + 1] = byte(green)
            logoData[logoOffset + 2] = byte(blue)
            logoData[logoOffset + 3] = byte(alpha)
        }
    }

    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.addRepresentation(logoRep)
    return image
}

let logoImage = try makeExtractedLogoImage()

func drawIconDesign() {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let tileRect = canvas.insetBy(dx: 104, dy: 104)
    let logoRect = canvas.insetBy(dx: 160, dy: 160)
    NSColor.clear.setFill()
    canvas.fill()

    NSGraphicsContext.saveGraphicsState()
    let backgroundPath = rounded(tileRect, radius: 176)
    backgroundPath.addClip()
    NSGradient(
        colors: [
            NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
            NSColor(deviceRed: 0.98, green: 0.99, blue: 1.0, alpha: 1),
            NSColor(deviceRed: 0.94, green: 0.97, blue: 1.0, alpha: 1)
        ]
    )?.draw(in: tileRect, angle: -35)
    NSGraphicsContext.restoreGraphicsState()

    NSColor(deviceRed: 0.82, green: 0.88, blue: 0.95, alpha: 0.55).setStroke()
    let borderPath = rounded(tileRect.insetBy(dx: 2, dy: 2), radius: 174)
    borderPath.lineWidth = 2
    borderPath.stroke()

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 34
    shadow.shadowColor = NSColor(deviceRed: 0.05, green: 0.20, blue: 0.45, alpha: 0.20)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    logoImage.draw(in: logoRect, from: canvas, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    logoImage.draw(in: logoRect, from: canvas, operation: .sourceOver, fraction: 1)
}

func renderPNG(size: Int, to url: URL) throws {
    let rep = try makeBitmapRep(size: size)

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
