import Foundation

public enum PetMood: Equatable, Sendable {
    case ok
    case caution
    case critical
    case unknown
    case celebration

    /// Mirrors Quotakin's CapacityStatus thresholds numerically:
    /// ok >= 35%, caution 15..<35%, critical < 15%, nil unknown.
    public init(remainingPercent: Double?) {
        guard let remainingPercent else {
            self = .unknown
            return
        }
        if remainingPercent < 15 {
            self = .critical
        } else if remainingPercent < 35 {
            self = .caution
        } else {
            self = .ok
        }
    }

    /// The typed tracks this mood may play. Raw string names are derived from
    /// these so a typo can't slip past the compiler.
    public var allowedTracks: [PetTrackName] {
        switch self {
        case .ok:
            [.idle, .waving, .runningRight, .runningLeft]
        case .caution:
            [.waiting, .review]
        case .critical:
            [.failed]
        case .unknown:
            [.waiting]
        case .celebration:
            [.jumping]
        }
    }

    public var allowedTrackNames: [String] {
        allowedTracks.map(\.rawValue)
    }
}
