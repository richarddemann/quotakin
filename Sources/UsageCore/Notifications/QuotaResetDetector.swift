import Foundation

/// Detects quota-window resets by comparing two snapshot sets. A reset is a
/// matching `(provider, window)` whose `resetsAt` advanced to a later cycle
/// **and** whose remaining capacity went up — a genuine refill, not merely a
/// rescheduled reset time.
///
/// This is the model-level signal the pet celebration reuses (rather than a
/// second, view-local comparison), so a reset is recognized on the refresh
/// loop regardless of whether the popover is open or notifications are enabled.
public enum QuotaResetDetector {
    public static func didReset(previous: QuotaSnapshot, current: QuotaSnapshot) -> Bool {
        current.resetsAt > previous.resetsAt
            && current.remainingPercent > previous.remainingPercent
    }

    public static func resetProviders(
        previous: [QuotaSnapshot],
        current: [QuotaSnapshot]
    ) -> Set<Provider> {
        var result: Set<Provider> = []
        for snapshot in current {
            guard let prior = previous.first(where: {
                $0.provider == snapshot.provider && $0.window == snapshot.window
            }) else {
                continue
            }
            if didReset(previous: prior, current: snapshot) {
                result.insert(snapshot.provider)
            }
        }
        return result
    }
}
