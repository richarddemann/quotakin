import Foundation

public struct PetAnimationFrame: Equatable, Sendable {
    public let spriteIndex: Int
    public let duration: Duration

    public init(spriteIndex: Int, duration: Duration) {
        self.spriteIndex = spriteIndex
        self.duration = duration
    }
}

public struct PetAnimationTrack: Equatable, Sendable {
    public let name: String
    public let frames: [PetAnimationFrame]
    public let loopStart: Int?
    public let fallback: String

    public init(
        name: String,
        frames: [PetAnimationFrame],
        loopStart: Int? = nil,
        fallback: String
    ) {
        self.name = name
        self.frames = frames
        self.loopStart = loopStart
        self.fallback = fallback
    }

    public func frame(at elapsed: Duration) -> (spriteIndex: Int, nextBoundary: Duration?) {
        precondition(!frames.isEmpty, "PetAnimationTrack requires at least one frame")
        guard frames.count > 1 else {
            return (frames[0].spriteIndex, nil)
        }

        let elapsedMilliseconds = max(0, elapsed.millisecondsValue)
        var cursor: Int64 = 0

        if let loopStart {
            precondition(frames.indices.contains(loopStart), "loopStart must be a valid frame index")
            for index in 0..<loopStart {
                let duration = frames[index].duration.millisecondsValue
                let boundary = cursor + duration
                if elapsedMilliseconds < boundary {
                    return (frames[index].spriteIndex, .milliseconds(boundary))
                }
                cursor = boundary
            }

            let loopDurations = frames[loopStart...].map(\.duration.millisecondsValue)
            let loopDuration = loopDurations.reduce(0, +)
            guard loopDuration > 0 else {
                return (frames[loopStart].spriteIndex, nil)
            }

            let loopElapsed = (elapsedMilliseconds - cursor) % loopDuration
            var loopCursor: Int64 = 0
            for index in loopStart..<frames.count {
                let duration = frames[index].duration.millisecondsValue
                let boundary = loopCursor + duration
                if loopElapsed < boundary {
                    return (frames[index].spriteIndex, .milliseconds(elapsedMilliseconds + (boundary - loopElapsed)))
                }
                loopCursor = boundary
            }
            return (frames[loopStart].spriteIndex, .milliseconds(elapsedMilliseconds + loopDuration))
        }

        for frame in frames {
            let boundary = cursor + frame.duration.millisecondsValue
            if elapsedMilliseconds < boundary {
                return (frame.spriteIndex, .milliseconds(boundary))
            }
            cursor = boundary
        }

        return (frames[frames.count - 1].spriteIndex, nil)
    }
}

extension PetAnimationTrack {
    public static func idleAmbient() -> PetAnimationTrack {
        let idle = PetSpriteGrid.idleRow
        let frames = zip(idle.spriteIndices, idle.durations).map { spriteIndex, duration in
            PetAnimationFrame(spriteIndex: spriteIndex, duration: duration * 6)
        }
        return PetAnimationTrack(name: PetTrackName.idle.rawValue, frames: frames, loopStart: 0, fallback: PetTrackName.idle.rawValue)
    }

    public static func appState(row: PetAnimationRow) -> PetAnimationTrack {
        let primaryFrames = zip(row.spriteIndices, row.durations).map { spriteIndex, duration in
            PetAnimationFrame(spriteIndex: spriteIndex, duration: duration)
        }
        let repeatedPrimary = Array(repeating: primaryFrames, count: 3).flatMap { $0 }
        let idleFrames = idleAmbient().frames
        return PetAnimationTrack(
            name: row.name,
            frames: repeatedPrimary + idleFrames,
            loopStart: repeatedPrimary.count,
            fallback: "idle"
        )
    }
}

private extension Duration {
    var millisecondsValue: Int64 {
        let components = self.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
