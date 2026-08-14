import CoreGraphics
import Foundation

public enum PetSpriteGrid {
    public static let sheetWidth = 1_536
    public static let sheetHeight = 1_872
    public static let columns = 8
    public static let rows = 9
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let totalFrames = columns * rows

    public static func rect(row: Int, column: Int) -> CGRect {
        CGRect(
            x: column * cellWidth,
            y: row * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }
}

public struct PetAnimationRow: Equatable, Sendable {
    public let name: String
    public let row: Int
    public let frameCount: Int
    public let durations: [Duration]

    public init(name: String, row: Int, frameCount: Int, durations: [Duration]) {
        self.name = name
        self.row = row
        self.frameCount = frameCount
        self.durations = durations
    }

    public var spriteIndices: [Int] {
        (0..<frameCount).map { row * PetSpriteGrid.columns + $0 }
    }
}

extension PetSpriteGrid {
    /// The idle row exposed as a non-optional constant so callers that always
    /// need idle (ambient loops, fallbacks) never force-unwrap a dictionary.
    public static let idleRow = PetAnimationRow(name: PetTrackName.idle.rawValue, row: 0, frameCount: 6, durations: ms([280, 110, 110, 140, 140, 320]))

    public static let canonicalRows: [PetAnimationRow] = [
        idleRow,
        PetAnimationRow(name: PetTrackName.runningRight.rawValue, row: 1, frameCount: 8, durations: ms([120, 120, 120, 120, 120, 120, 120, 220])),
        PetAnimationRow(name: PetTrackName.runningLeft.rawValue, row: 2, frameCount: 8, durations: ms([120, 120, 120, 120, 120, 120, 120, 220])),
        PetAnimationRow(name: PetTrackName.waving.rawValue, row: 3, frameCount: 4, durations: ms([140, 140, 140, 280])),
        PetAnimationRow(name: PetTrackName.jumping.rawValue, row: 4, frameCount: 5, durations: ms([140, 140, 140, 140, 280])),
        PetAnimationRow(name: PetTrackName.failed.rawValue, row: 5, frameCount: 8, durations: ms([140, 140, 140, 140, 140, 140, 140, 240])),
        PetAnimationRow(name: PetTrackName.waiting.rawValue, row: 6, frameCount: 6, durations: ms([150, 150, 150, 150, 150, 260])),
        PetAnimationRow(name: PetTrackName.running.rawValue, row: 7, frameCount: 6, durations: ms([120, 120, 120, 120, 120, 220])),
        PetAnimationRow(name: PetTrackName.review.rawValue, row: 8, frameCount: 6, durations: ms([150, 150, 150, 150, 150, 280]))
    ]

    public static let rowsByName: [String: PetAnimationRow] = {
        Dictionary(uniqueKeysWithValues: canonicalRows.map { ($0.name, $0) })
    }()

    private static func ms(_ values: [Int]) -> [Duration] {
        values.map { .milliseconds($0) }
    }
}
