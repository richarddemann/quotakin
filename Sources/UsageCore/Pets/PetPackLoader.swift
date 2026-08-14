import CoreGraphics
import Foundation
import ImageIO

public struct PetManifest: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public let width: Int?
        public let height: Int?
        public let columns: Int?
        public let rows: Int?

        public init(width: Int? = nil, height: Int? = nil, columns: Int? = nil, rows: Int? = nil) {
            self.width = width
            self.height = height
            self.columns = columns
            self.rows = rows
        }
    }

    public struct Animation: Codable, Equatable, Sendable {
        public let frames: [Int]
        public let fps: Double?
        public let loop: Bool?
        public let fallback: String?

        public init(frames: [Int], fps: Double? = nil, loop: Bool? = nil, fallback: String? = nil) {
            self.frames = frames
            self.fps = fps
            self.loop = loop
            self.fallback = fallback
        }
    }

    public let id: String?
    public let displayName: String?
    public let description: String?
    public let spritesheetPath: String?
    public let frame: Frame?
    public let animations: [String: Animation]?

    public init(
        id: String? = nil,
        displayName: String? = nil,
        description: String? = nil,
        spritesheetPath: String? = nil,
        frame: Frame? = nil,
        animations: [String: Animation]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
        self.frame = frame
        self.animations = animations
    }
}

public struct PetPack: Equatable, Sendable {
    public let id: String
    public let directoryName: String
    public let manifest: PetManifest
    public let spritesheetURL: URL
}

public struct PetPackDiagnostic: Equatable, Sendable {
    public let packDirectoryName: String
    public let reason: String
}

public struct PetPackLoadResult: Equatable, Sendable {
    public let packs: [PetPack]
    public let diagnostics: [PetPackDiagnostic]
}

public struct PetPackLoader {
    public let rootURLs: [URL]
    private let fileManager: FileManager

    public init(rootURLs: [URL], fileManager: FileManager = .default) {
        self.rootURLs = rootURLs
        self.fileManager = fileManager
    }

    public func load() -> PetPackLoadResult {
        var packs: [PetPack] = []
        var diagnostics: [PetPackDiagnostic] = []
        var seenIDs: Set<String> = []

        for rootURL in rootURLs {
            guard let packURLs = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for packURL in packURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDirectory(packURL) else {
                    continue
                }
                do {
                    let pack = try validatePack(at: packURL)
                    guard !seenIDs.contains(pack.id) else {
                        continue
                    }
                    seenIDs.insert(pack.id)
                    packs.append(pack)
                } catch {
                    diagnostics.append(
                        PetPackDiagnostic(
                            packDirectoryName: packURL.lastPathComponent,
                            reason: sanitizedReason(for: error)
                        )
                    )
                }
            }
        }

        return PetPackLoadResult(packs: packs, diagnostics: diagnostics)
    }

    private func validatePack(at packURL: URL) throws -> PetPack {
        let manifestURL = packURL.appendingPathComponent("pet.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ValidationError.missingManifest
        }

        let manifest: PetManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PetManifest.self, from: data)
        } catch {
            throw ValidationError.malformedManifest
        }

        let spritesheetPath = manifest.spritesheetPath ?? "spritesheet.webp"
        let spritesheetURL = try resolveSpritesheet(path: spritesheetPath, in: packURL)
        guard fileManager.fileExists(atPath: spritesheetURL.path) else {
            throw ValidationError.missingSpritesheet(spritesheetPath)
        }

        let dimensions = try imageDimensions(at: spritesheetURL)
        guard dimensions.width == PetSpriteGrid.sheetWidth,
              dimensions.height == PetSpriteGrid.sheetHeight
        else {
            throw ValidationError.wrongDimensions
        }

        let frameWidth = manifest.frame?.width ?? PetSpriteGrid.cellWidth
        let frameHeight = manifest.frame?.height ?? PetSpriteGrid.cellHeight
        let columns = manifest.frame?.columns ?? PetSpriteGrid.columns
        let rows = manifest.frame?.rows ?? PetSpriteGrid.rows

        guard frameWidth > 0, frameHeight > 0, columns > 0, rows > 0 else {
            throw ValidationError.gridMismatch
        }
        guard frameWidth * columns == dimensions.width,
              frameHeight * rows == dimensions.height
        else {
            throw ValidationError.gridMismatch
        }

        let totalFrames = columns * rows
        guard totalFrames <= 256 else {
            throw ValidationError.tooManyFrames
        }

        try validateAnimations(manifest.animations, totalFrames: totalFrames)

        return PetPack(
            id: manifest.id ?? packURL.lastPathComponent,
            directoryName: packURL.lastPathComponent,
            manifest: manifest,
            spritesheetURL: spritesheetURL
        )
    }

    private func resolveSpritesheet(path: String, in packURL: URL) throws -> URL {
        guard !path.isEmpty else {
            throw ValidationError.pathEscape
        }
        guard !path.hasPrefix("/") else {
            throw ValidationError.pathEscape
        }
        guard !path.split(separator: "/").contains("..") else {
            throw ValidationError.pathEscape
        }

        let base = packURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(basePath) else {
            throw ValidationError.pathEscape
        }
        return resolved
    }

    private func imageDimensions(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ValidationError.unreadableSpritesheet
        }
        return (width, height)
    }

    private func validateAnimations(_ animations: [String: PetManifest.Animation]?, totalFrames: Int) throws {
        guard let animations else {
            return
        }

        for (_, animation) in animations {
            guard !animation.frames.isEmpty else {
                throw ValidationError.emptyAnimation
            }
            if let fps = animation.fps, !fps.isFinite || fps <= 0 || fps > 60 {
                throw ValidationError.badFPS
            }
            guard animation.frames.allSatisfy({ $0 >= 0 && $0 < totalFrames }) else {
                throw ValidationError.frameIndexOutOfRange
            }
        }

        // Custom animations layer over the built-in canonical tracks (the
        // Codex reference loader merges them the same way), so a fallback may
        // name either a sibling custom animation or any canonical row.
        for (_, animation) in animations {
            let fallback = animation.fallback ?? "idle"
            guard animations.keys.contains(fallback)
                || PetSpriteGrid.rowsByName.keys.contains(fallback)
            else {
                throw ValidationError.missingFallback
            }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func sanitizedReason(for error: Error) -> String {
        switch error as? ValidationError {
        case .missingManifest:
            "missing pet.json"
        case .malformedManifest:
            "malformed pet.json"
        case .pathEscape:
            "spritesheet path must stay inside pack directory"
        case .missingSpritesheet(let path):
            "missing spritesheet \(path)"
        case .unreadableSpritesheet:
            "spritesheet could not be decoded"
        case .wrongDimensions:
            "spritesheet dimensions must be 1536x1872"
        case .gridMismatch:
            "frame grid must tile the spritesheet exactly"
        case .tooManyFrames:
            "frame grid must contain 256 frames or fewer"
        case .emptyAnimation:
            "animation frames must not be empty"
        case .badFPS:
            "animation fps must be in (0, 60]"
        case .frameIndexOutOfRange:
            "animation frame index is out of range"
        case .missingFallback:
            "animation fallback must name an existing animation"
        case .none:
            "pack is malformed"
        }
    }

    private enum ValidationError: Error {
        case missingManifest
        case malformedManifest
        case pathEscape
        case missingSpritesheet(String)
        case unreadableSpritesheet
        case wrongDimensions
        case gridMismatch
        case tooManyFrames
        case emptyAnimation
        case badFPS
        case frameIndexOutOfRange
        case missingFallback
    }
}
