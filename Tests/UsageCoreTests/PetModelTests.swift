import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UsageCore

@Test
func petSpriteGridConstantsRowsAndRectMathMatchCodexAtlas() {
    #expect(PetSpriteGrid.sheetWidth == 1_536)
    #expect(PetSpriteGrid.sheetHeight == 1_872)
    #expect(PetSpriteGrid.columns == 8)
    #expect(PetSpriteGrid.rows == 9)
    #expect(PetSpriteGrid.cellWidth == 192)
    #expect(PetSpriteGrid.cellHeight == 208)
    #expect(PetSpriteGrid.rect(row: 2, column: 3) == CGRect(x: 576, y: 416, width: 192, height: 208))

    #expect(PetSpriteGrid.rowsByName["idle"]?.durations == [.milliseconds(280), .milliseconds(110), .milliseconds(110), .milliseconds(140), .milliseconds(140), .milliseconds(320)])
    #expect(PetSpriteGrid.rowsByName["running-right"]?.durations == [.milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(220)])
    #expect(PetSpriteGrid.rowsByName["running-left"]?.durations == [.milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(220)])
    #expect(PetSpriteGrid.rowsByName["waving"]?.durations == [.milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(280)])
    #expect(PetSpriteGrid.rowsByName["jumping"]?.durations == [.milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(280)])
    #expect(PetSpriteGrid.rowsByName["failed"]?.durations == [.milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(140), .milliseconds(240)])
    #expect(PetSpriteGrid.rowsByName["waiting"]?.durations == [.milliseconds(150), .milliseconds(150), .milliseconds(150), .milliseconds(150), .milliseconds(150), .milliseconds(260)])
    #expect(PetSpriteGrid.rowsByName["running"]?.durations == [.milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(120), .milliseconds(220)])
    #expect(PetSpriteGrid.rowsByName["review"]?.durations == [.milliseconds(150), .milliseconds(150), .milliseconds(150), .milliseconds(150), .milliseconds(150), .milliseconds(280)])
}

@Test
func petAnimationTrackWrapsLoopSegmentAtExactBoundaries() {
    let track = PetAnimationTrack(
        name: "custom",
        frames: [
            PetAnimationFrame(spriteIndex: 1, duration: .milliseconds(100)),
            PetAnimationFrame(spriteIndex: 2, duration: .milliseconds(200)),
            PetAnimationFrame(spriteIndex: 3, duration: .milliseconds(300))
        ],
        loopStart: 1,
        fallback: "idle"
    )

    #expect(track.frame(at: .zero).spriteIndex == 1)
    #expect(track.frame(at: .zero).nextBoundary == .milliseconds(100))
    #expect(track.frame(at: .milliseconds(100)).spriteIndex == 2)
    #expect(track.frame(at: .milliseconds(100)).nextBoundary == .milliseconds(300))
    #expect(track.frame(at: .milliseconds(300)).spriteIndex == 3)
    #expect(track.frame(at: .milliseconds(300)).nextBoundary == .milliseconds(600))
    #expect(track.frame(at: .milliseconds(600)).spriteIndex == 2)
    #expect(track.frame(at: .milliseconds(600)).nextBoundary == .milliseconds(800))

    let oneShot = PetAnimationTrack(
        name: "one-shot",
        frames: [
            PetAnimationFrame(spriteIndex: 4, duration: .milliseconds(100)),
            PetAnimationFrame(spriteIndex: 5, duration: .milliseconds(200))
        ],
        fallback: "idle"
    )
    #expect(oneShot.frame(at: .milliseconds(500)).spriteIndex == 5)
    #expect(oneShot.frame(at: .milliseconds(500)).nextBoundary == nil)

    let single = PetAnimationTrack(
        name: "single",
        frames: [PetAnimationFrame(spriteIndex: 9, duration: .milliseconds(100))],
        fallback: "idle"
    )
    #expect(single.frame(at: .milliseconds(50)).spriteIndex == 9)
    #expect(single.frame(at: .milliseconds(50)).nextBoundary == nil)
}

@Test
func appStateTrackRepeatsPrimaryRowThreeTimesThenChainsIdleLoop() throws {
    let row = try #require(PetSpriteGrid.rowsByName["waiting"])
    let track = PetAnimationTrack.appState(row: row)
    let primaryCount = row.frameCount * 3

    #expect(track.name == "waiting")
    #expect(track.loopStart == primaryCount)
    #expect(track.fallback == "idle")
    #expect(track.frames.count == primaryCount + 6)
    #expect(track.frames[0].spriteIndex == row.row * PetSpriteGrid.columns)
    #expect(track.frames[primaryCount].spriteIndex == 0)
    #expect(track.frames[primaryCount].duration == .milliseconds(1_680))
}

@Test
func petMoodBandsAndTrackMappingsMatchCapacityStatusThresholds() {
    #expect(PetMood(remainingPercent: nil) == .unknown)
    #expect(PetMood(remainingPercent: 14.999) == .critical)
    #expect(PetMood(remainingPercent: 15) == .caution)
    #expect(PetMood(remainingPercent: 34.999) == .caution)
    #expect(PetMood(remainingPercent: 35) == .ok)

    #expect(PetMood.ok.allowedTrackNames == ["idle", "waving", "running-right", "running-left"])
    #expect(PetMood.caution.allowedTrackNames == ["waiting", "review"])
    #expect(PetMood.critical.allowedTrackNames == ["failed"])
    #expect(PetMood.unknown.allowedTrackNames == ["waiting"])
    #expect(PetMood.celebration.allowedTrackNames == ["jumping"])
}

@Test
func petBehaviorEngineIsDeterministicEnforcesMinimumDisplayAndClampsX() {
    var firstEngine = PetBehaviorEngine()
    var secondEngine = PetBehaviorEngine()
    var firstRNG = SeededRandomNumberGenerator(seed: 42)
    var secondRNG = SeededRandomNumberGenerator(seed: 42)

    let firstInitial = firstEngine.state(mood: .ok, elapsedTime: 0, rng: &firstRNG, remainingFraction: 0.8)
    let secondInitial = secondEngine.state(mood: .ok, elapsedTime: 0, rng: &secondRNG, remainingFraction: 0.8)
    #expect(firstInitial == secondInitial)

    let held = firstEngine.state(mood: .critical, elapsedTime: 1.0, rng: &firstRNG, remainingFraction: 0.8)
    #expect(held.trackName == firstInitial.trackName)
    #expect(held.activityStartTime == firstInitial.activityStartTime)

    let changed = firstEngine.state(mood: .critical, elapsedTime: 1.6, rng: &firstRNG, remainingFraction: 0.8)
    #expect(changed.trackName == "failed")
    #expect(changed.activityStartTime == 1.6)

    let clamped = firstEngine.state(mood: .critical, elapsedTime: 2.0, rng: &firstRNG, remainingFraction: 0.05)
    #expect(clamped.xPositionFraction >= 0)
    #expect(clamped.xPositionFraction <= 0.05)

    let celebrating = firstEngine.state(mood: .celebration, elapsedTime: 3.0, rng: &firstRNG, remainingFraction: 0.05)
    #expect(celebrating.trackName == "jumping")
    let afterCelebration = firstEngine.state(mood: .celebration, elapsedTime: 6.1, rng: &firstRNG, remainingFraction: 0.05)
    #expect(afterCelebration.trackName == "failed")
}

@Test
func petPackLoaderLoadsValidPacksAndKeepsFirstDuplicateID() throws {
    let temp = try TemporaryDirectory()
    let firstRoot = temp.url.appendingPathComponent("bundled")
    let secondRoot = temp.url.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)

    try makePack(in: firstRoot, directoryName: "alpha", manifest: PetManifest(id: "same-id", displayName: "Alpha"))
    try makePack(in: secondRoot, directoryName: "beta", manifest: PetManifest(id: "same-id", displayName: "Beta"))
    try makePack(in: secondRoot, directoryName: "gamma", manifest: PetManifest(id: nil, displayName: "Gamma"))

    let result = PetPackLoader(rootURLs: [firstRoot, secondRoot]).load()

    #expect(result.diagnostics.isEmpty)
    #expect(result.packs.map(\.id) == ["same-id", "gamma"])
    #expect(result.packs.map(\.directoryName) == ["alpha", "gamma"])
    #expect(result.packs[0].manifest.spritesheetPath == nil)
}

@Test
func petPackLoaderSkipsMalformedPacksWithSanitizedDiagnostics() throws {
    let temp = try TemporaryDirectory()
    let root = temp.url.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    try makePack(in: root, directoryName: "pathEscape", manifest: PetManifest(spritesheetPath: "../spritesheet.png"), writeSheet: false)
    try makePack(in: root, directoryName: "missingSheet", manifest: PetManifest(spritesheetPath: "missing.png"), writeSheet: false)
    try makePack(in: root, directoryName: "wrongDimensions", manifest: PetManifest(spritesheetPath: "spritesheet.png"), imageSize: CGSize(width: 10, height: 10))
    try makePack(in: root, directoryName: "gridMismatch", manifest: PetManifest(spritesheetPath: "spritesheet.png", frame: .init(width: 200, height: 208, columns: 8, rows: 9)))
    try makePack(in: root, directoryName: "frameCap", manifest: PetManifest(spritesheetPath: "spritesheet.png", frame: .init(width: 96, height: 52, columns: 16, rows: 36)))
    try makePack(
        in: root,
        directoryName: "badFPS",
        manifest: PetManifest(
            spritesheetPath: "spritesheet.png",
            animations: ["idle": .init(frames: [0], fps: 0, fallback: "idle")]
        )
    )
    try makePack(
        in: root,
        directoryName: "outOfRange",
        manifest: PetManifest(
            spritesheetPath: "spritesheet.png",
            animations: ["idle": .init(frames: [72], fallback: "idle")]
        )
    )
    try makePack(
        in: root,
        directoryName: "missingFallback",
        manifest: PetManifest(
            spritesheetPath: "spritesheet.png",
            animations: ["idle": .init(frames: [0], fallback: "missing")]
        )
    )
    try makePack(
        in: root,
        directoryName: "canonicalFallback",
        manifest: PetManifest(
            id: "canonical-fallback",
            spritesheetPath: "spritesheet.png",
            animations: ["blink": .init(frames: [0, 1])]
        )
    )

    let result = PetPackLoader(rootURLs: [root]).load()
    let reasonsByPack = Dictionary(uniqueKeysWithValues: result.diagnostics.map { ($0.packDirectoryName, $0.reason) })

    // A custom animation without an explicit fallback defaults to "idle",
    // which is a canonical track even when the pack doesn't declare it.
    #expect(result.packs.map(\.id) == ["canonical-fallback"])
    #expect(reasonsByPack["pathEscape"] == "spritesheet path must stay inside pack directory")
    #expect(reasonsByPack["missingSheet"] == "missing spritesheet missing.png")
    #expect(reasonsByPack["wrongDimensions"] == "spritesheet dimensions must be 1536x1872")
    #expect(reasonsByPack["gridMismatch"] == "frame grid must tile the spritesheet exactly")
    #expect(reasonsByPack["frameCap"] == "frame grid must contain 256 frames or fewer")
    #expect(reasonsByPack["badFPS"] == "animation fps must be in (0, 60]")
    #expect(reasonsByPack["outOfRange"] == "animation frame index is out of range")
    #expect(reasonsByPack["missingFallback"] == "animation fallback must name an existing animation")

    let allReasons = result.diagnostics.map(\.reason).joined(separator: "\n")
    #expect(!allReasons.contains(temp.url.path))
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageCorePetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makePack(
    in root: URL,
    directoryName: String,
    manifest: PetManifest,
    writeSheet: Bool = true,
    imageSize: CGSize = CGSize(width: PetSpriteGrid.sheetWidth, height: PetSpriteGrid.sheetHeight)
) throws {
    let packURL = root.appendingPathComponent(directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: packURL, withIntermediateDirectories: true)

    let manifestData = try JSONEncoder().encode(manifest)
    try manifestData.write(to: packURL.appendingPathComponent("pet.json"))

    guard writeSheet else {
        return
    }
    let sheetName = manifest.spritesheetPath ?? "spritesheet.webp"
    try writePNG(at: packURL.appendingPathComponent(sheetName), width: Int(imageSize.width), height: Int(imageSize.height))
}

private func writePNG(at url: URL, width: Int, height: Int) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw TestImageError.context
    }
    context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw TestImageError.destination
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TestImageError.finalize
    }
}

private enum TestImageError: Error {
    case context
    case destination
    case finalize
}
