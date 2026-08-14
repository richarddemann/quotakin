import Foundation

public struct PetBehaviorState: Equatable, Sendable {
    public let trackName: String
    public let activityStartTime: TimeInterval
    public let xPositionFraction: Double
}

public struct PetBehaviorEngine: Equatable, Sendable {
    public static let dwellRange: ClosedRange<TimeInterval> = 4...10
    public static let minimumDisplayTime: TimeInterval = 1.5
    public static let celebrationDuration: TimeInterval = 3

    private var currentTrackName: String?
    private var activityStartTime: TimeInterval = 0
    private var activityDwell: TimeInterval = 0
    private var xPositionFraction: Double = 0
    private var lastMood: PetMood = .unknown
    private var celebrationStartedAt: TimeInterval?

    public init() {}

    public mutating func state(
        mood requestedMood: PetMood,
        elapsedTime: TimeInterval,
        rng: inout some RandomNumberGenerator,
        remainingFraction: Double
    ) -> PetBehaviorState {
        let clampedWidth = min(max(remainingFraction, 0), 1)
        xPositionFraction = min(max(xPositionFraction, 0), clampedWidth)

        if requestedMood != .celebration {
            lastMood = requestedMood
            celebrationStartedAt = nil
        }

        let effectiveMood: PetMood
        if requestedMood == .celebration {
            if let startedAt = celebrationStartedAt,
               elapsedTime - startedAt >= Self.celebrationDuration {
                effectiveMood = lastMood == .celebration ? .ok : lastMood
            } else {
                effectiveMood = .celebration
            }
        } else {
            effectiveMood = requestedMood
        }

        if currentTrackName == nil {
            startActivity(for: effectiveMood, at: elapsedTime, rng: &rng, remainingFraction: clampedWidth)
        } else if effectiveMood == .celebration, currentTrackName != PetTrackName.jumping.rawValue {
            startActivity(for: .celebration, at: elapsedTime, rng: &rng, remainingFraction: clampedWidth)
            celebrationStartedAt = elapsedTime
        } else if currentTrackName == PetTrackName.jumping.rawValue, elapsedTime - activityStartTime < Self.celebrationDuration {
            xPositionFraction = min(xPositionFraction, clampedWidth)
        } else {
            let allowed = effectiveMood.allowedTrackNames
            let hasMoodMismatch = currentTrackName.map { !allowed.contains($0) } ?? true
            let minimumDisplayElapsed = elapsedTime - activityStartTime >= Self.minimumDisplayTime
            let dwellElapsed = elapsedTime - activityStartTime >= activityDwell

            if hasMoodMismatch && minimumDisplayElapsed {
                startActivity(for: effectiveMood, at: elapsedTime, rng: &rng, remainingFraction: clampedWidth)
            } else if dwellElapsed && !hasMoodMismatch {
                startActivity(for: effectiveMood, at: elapsedTime, rng: &rng, remainingFraction: clampedWidth)
            }
        }

        xPositionFraction = min(max(xPositionFraction, 0), clampedWidth)
        return PetBehaviorState(
            trackName: currentTrackName ?? PetTrackName.waiting.rawValue,
            activityStartTime: activityStartTime,
            xPositionFraction: xPositionFraction
        )
    }

    private mutating func startActivity(
        for mood: PetMood,
        at elapsedTime: TimeInterval,
        rng: inout some RandomNumberGenerator,
        remainingFraction: Double
    ) {
        let tracks = mood.allowedTrackNames
        currentTrackName = tracks[Int.random(in: tracks.indices, using: &rng)]
        activityStartTime = elapsedTime
        activityDwell = mood == .celebration
            ? Self.celebrationDuration
            : TimeInterval.random(in: Self.dwellRange, using: &rng)
        xPositionFraction = Double.random(in: 0...remainingFraction, using: &rng)
        if mood == .celebration {
            celebrationStartedAt = elapsedTime
        }
    }
}
