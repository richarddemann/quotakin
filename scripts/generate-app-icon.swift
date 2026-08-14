import AppKit
import Foundation

private struct IconVariant {
    let pixels: Int
    let icnsType: String
}

private let variants = [
    IconVariant(pixels: 16, icnsType: "icp4"),
    IconVariant(pixels: 32, icnsType: "icp5"),
    IconVariant(pixels: 128, icnsType: "ic07"),
    IconVariant(pixels: 256, icnsType: "ic08"),
    IconVariant(pixels: 512, icnsType: "ic09"),
    IconVariant(pixels: 1_024, icnsType: "ic10"),
    IconVariant(pixels: 32, icnsType: "ic11"),
    IconVariant(pixels: 64, icnsType: "ic12"),
    IconVariant(pixels: 256, icnsType: "ic13"),
    IconVariant(pixels: 512, icnsType: "ic14")
]

guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("Usage: generate-app-icon.swift <output.icns> [preview.png]\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let masterPNG = try renderIcon(pixels: 1_024)
var chunks = Data()
for variant in variants {
    let png = variant.pixels == 1_024
        ? masterPNG
        : try resizedPNG(masterPNG, pixels: variant.pixels)
    chunks.append(contentsOf: variant.icnsType.utf8)
    chunks.appendBigEndianUInt32(UInt32(png.count + 8))
    chunks.append(png)
}

var icns = Data("icns".utf8)
icns.appendBigEndianUInt32(UInt32(chunks.count + 8))
icns.append(chunks)
try icns.write(to: outputURL, options: .atomic)

if CommandLine.arguments.count == 3 {
    try masterPNG.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}

private func resizedPNG(_ sourceData: Data, pixels: Int) throws -> Data {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-icon-resize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let sourceURL = temporaryDirectory.appendingPathComponent("master.png")
    let resizedURL = temporaryDirectory.appendingPathComponent("\(pixels).png")
    try sourceData.write(to: sourceURL, options: .atomic)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-z", String(pixels), String(pixels),
        sourceURL.path,
        "--out", resizedURL.path
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconGenerationError.resizeFailed(process.terminationStatus)
    }
    return try Data(contentsOf: resizedURL)
}

private func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconGenerationError.bitmapAllocationFailed
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGenerationError.graphicsContextFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.cgContext.scaleBy(x: CGFloat(pixels) / 1_024, y: CGFloat(pixels) / 1_024)
    graphicsContext.shouldAntialias = true
    graphicsContext.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.pngEncodingFailed
    }
    return png
}

private func drawIcon() {
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1_024, height: 1_024).fill()

    let shadow = NSBezierPath(roundedRect: NSRect(x: 42, y: 28, width: 940, height: 940), xRadius: 218, yRadius: 218)
    NSColor(calibratedRed: 7 / 255, green: 17 / 255, blue: 29 / 255, alpha: 0.34).setFill()
    shadow.fill()

    let tile = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 218, yRadius: 218)
    let background = NSGradient(colors: [
        NSColor(calibratedRed: 39 / 255, green: 60 / 255, blue: 88 / 255, alpha: 1),
        NSColor(calibratedRed: 23 / 255, green: 38 / 255, blue: 56 / 255, alpha: 1),
        NSColor(calibratedRed: 16 / 255, green: 26 / 255, blue: 39 / 255, alpha: 1)
    ])!
    background.draw(in: tile, angle: -55)

    let rim = NSBezierPath(roundedRect: NSRect(x: 53, y: 53, width: 918, height: 918), xRadius: 207, yRadius: 207)
    rim.lineWidth = 10
    NSColor.white.withAlphaComponent(0.12).setStroke()
    rim.stroke()

    let baseline = NSBezierPath()
    baseline.move(to: NSPoint(x: 260, y: 234))
    baseline.line(to: NSPoint(x: 764, y: 234))
    baseline.lineWidth = 24
    baseline.lineCapStyle = .round
    NSColor(calibratedRed: 216 / 255, green: 1, blue: 244 / 255, alpha: 0.22).setStroke()
    baseline.stroke()

    let barGradient = NSGradient(colors: [
        NSColor(calibratedRed: 81 / 255, green: 199 / 255, blue: 191 / 255, alpha: 1),
        NSColor(calibratedRed: 132 / 255, green: 224 / 255, blue: 178 / 255, alpha: 1)
    ])!
    let bars = [
        NSRect(x: 246, y: 234, width: 132, height: 198),
        NSRect(x: 446, y: 234, width: 132, height: 360),
        NSRect(x: 646, y: 234, width: 132, height: 524)
    ]
    for rect in bars {
        let path = NSBezierPath(roundedRect: rect, xRadius: 54, yRadius: 54)
        barGradient.draw(in: path, angle: 90)
    }

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0),
        NSColor.white.withAlphaComponent(0.16)
    ])!
    highlight.draw(in: NSRect(x: 42, y: 520, width: 940, height: 462), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
}

private enum IconGenerationError: Error {
    case bitmapAllocationFailed
    case graphicsContextFailed
    case pngEncodingFailed
    case resizeFailed(Int32)
}

private extension Data {
    mutating func appendBigEndianUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
