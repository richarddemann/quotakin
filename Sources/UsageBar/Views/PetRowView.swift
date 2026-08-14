import SwiftUI
import UsageCore

struct PetRowView: View {
    let summary: ProviderSummary
    let presentation: ProviderCardPresentation
    let primary: QuotaSnapshot
    let quotaDisplayMode: QuotaDisplayMode
    let pack: PetPack
    let showProviderName: Bool
    /// Model-level "this provider's window just reset" pulse (AppModel
    /// `lastWindowResetAt`). A change while the row is on screen triggers a
    /// celebration; reuses the same signal as the reset notification instead of
    /// re-deriving it here. Optional/defaulted so callers can omit it.
    var resetPulse: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = PetBehaviorEngine()
    @State private var behaviorState: PetBehaviorState?
    @State private var rng = SystemRandomNumberGenerator()
    @State private var celebrationUntil: Date?
    @State private var lastCelebratedPulse: Date?

    private let petSize = CGSize(width: 40, height: 44)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: Space.xs) {
                if showProviderName {
                    Text(summary.provider.displayName)
                        .font(.subheadline.weight(.semibold))
                }

                QuotaHeadlineView(
                    snapshot: primary,
                    presentation: presentation,
                    quotaDisplayMode: quotaDisplayMode
                ) {
                    petGround
                }
            }
            .accessibilityRepresentation {
                Text(summary.provider.displayName)
                Text("\(presentation.windowTitle(for: primary.window)), \(presentation.quotaText(for: primary)), \(presentation.resetDetail(for: primary))")
            }
            .onAppear {
                tick(at: context.date)
            }
            .onChange(of: context.date) { _, date in
                tick(at: date)
            }
            .onChange(of: resetPulse) { _, pulse in
                celebrate(for: pulse)
            }
        }
    }

    private var petGround: some View {
        GeometryReader { proxy in
            let remainingFraction = primary.remainingPercent / 100
            let xPositionFraction = reduceMotion
                ? PetRowPresentation.reducedMotionXPositionFraction(remainingFraction: remainingFraction)
                : behaviorState?.xPositionFraction ?? 0
            let offset = PetRowPresentation.xOffset(
                trackWidth: proxy.size.width,
                petWidth: petSize.width,
                xPositionFraction: xPositionFraction,
                remainingFraction: remainingFraction
            )

            ZStack(alignment: .bottomLeading) {
                QuotaProgressView(snapshot: primary, quotaDisplayMode: quotaDisplayMode)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.bottom) { dimensions in dimensions[VerticalAlignment.center] }

                PetSpriteView(
                    pack: pack,
                    trackName: behaviorState?.trackName ?? PetTrackName.waiting.rawValue,
                    activityStartDate: Date(
                        timeIntervalSinceReferenceDate: behaviorState?.activityStartTime
                            ?? Date().timeIntervalSinceReferenceDate
                    ),
                    renderSize: petSize
                )
                .offset(x: offset, y: -3)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: offset)
            }
        }
        .frame(height: 48)
    }

    private func tick(at date: Date) {
        guard !reduceMotion else {
            // Reduced motion keeps the pet parked near the start of the
            // available track and skips the per-second wandering engine.
            return
        }

        var mood = PetMood(remainingPercent: primary.remainingPercent)
        if let celebrationUntil, date <= celebrationUntil {
            mood = .celebration
        }
        behaviorState = engine.state(
            mood: mood,
            elapsedTime: date.timeIntervalSinceReferenceDate,
            rng: &rng,
            remainingFraction: primary.remainingPercent / 100
        )
    }

    /// Celebrate a fresh reset pulse seen while the row is on screen. Guards
    /// against re-celebrating the same pulse (e.g. on repeated ticks) and skips
    /// under reduce motion. A reset that landed while the popover was closed
    /// isn't retro-celebrated on open — celebrations are a live delight.
    private func celebrate(for pulse: Date?) {
        guard !reduceMotion, let pulse, pulse != lastCelebratedPulse else {
            return
        }
        lastCelebratedPulse = pulse
        celebrationUntil = Date().addingTimeInterval(PetBehaviorEngine.celebrationDuration)
    }
}
