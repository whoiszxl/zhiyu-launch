// Generates Resources/AppIcon.icns for Zhiyu Launch.
//
// Run manually when the icon design changes:
//   swift scripts/generate_app_icon.swift Resources/AppIcon.icns
//
// The design: a purple gradient rounded square with a white 3×3 dot grid —
// the universal "launcher" motif.

import AppKit

func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else { return nil }

    ctx.interpolationQuality = .high

    // macOS icon proportions: ~8% margin, corner radius ~22.5% of the body.
    let margin = s * 0.08
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(srgbRed: 0.36, green: 0.29, blue: 0.92, alpha: 1),
        CGColor(srgbRed: 0.60, green: 0.38, blue: 0.97, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle top highlight for depth.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.fillEllipse(in: CGRect(x: rect.minX - rect.width * 0.25,
                               y: rect.midY,
                               width: rect.width * 1.5,
                               height: rect.height * 0.9))
    ctx.restoreGState()

    // 3×3 dot grid.
    let dotCount = 3
    let dotArea = rect.insetBy(dx: rect.width * 0.245, dy: rect.width * 0.245)
    let step = dotArea.width / CGFloat(dotCount)
    let dotRadius = step * 0.30
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
    for row in 0..<dotCount {
        for col in 0..<dotCount {
            let cx = dotArea.minX + step * (CGFloat(col) + 0.5)
            let cy = dotArea.minY + step * (CGFloat(row) + 0.5)
            ctx.fillEllipse(in: CGRect(x: cx - dotRadius, y: cy - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2))
        }
    }

    return ctx.makeImage()
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
// Note: iconutil requires the directory name to end in ".iconset".
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ZhiyuLaunch-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetURL) }

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for spec in specs {
    guard let cgImage = drawIcon(size: spec.pixels) else {
        FileHandle.standardError.write(Data("failed to draw \(spec.name)\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: iconsetURL.appendingPathComponent("\(spec.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(outputPath)")
