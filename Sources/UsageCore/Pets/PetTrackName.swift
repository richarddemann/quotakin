import Foundation

/// The nine canonical animation tracks shipped in every pet pack.
///
/// The `String` raw values are the manifest/pack boundary — pack JSON and the
/// loader continue to speak strings — but internal code should prefer the typed
/// cases so a misspelled track name fails at compile time instead of silently
/// falling back at runtime.
public enum PetTrackName: String, CaseIterable, Sendable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review
}
