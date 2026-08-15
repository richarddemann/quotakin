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

guard (3...4).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("Usage: generate-app-icon.swift <source.png> <output.icns> [preview.png]\n".utf8))
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let masterPNG = try renderIcon(sourceURL: sourceURL, pixels: 1_024)
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

if CommandLine.arguments.count == 4 {
    try masterPNG.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
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

private func renderIcon(sourceURL: URL, pixels: Int) throws -> Data {
    guard let sourceImage = NSImage(contentsOf: sourceURL) else {
        throw IconGenerationError.sourceImageUnreadable(sourceURL.path)
    }
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
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: 1_024, height: 1_024),
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.pngEncodingFailed
    }
    return png
}

private enum IconGenerationError: Error {
    case sourceImageUnreadable(String)
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
