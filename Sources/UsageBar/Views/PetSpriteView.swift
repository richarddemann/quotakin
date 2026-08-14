import AppKit
import SwiftUI
import UsageCore

struct PetSpriteView: View {
    let pack: PetPack
    let trackName: String
    let activityStartDate: Date
    var renderSize = CGSize(width: 40, height: 44)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let track = Self.track(named: reduceMotion ? PetTrackName.idle.rawValue : trackName)
        let schedule = reduceMotion
            ? nil
            : PetFrameTimelineSchedule(track: track, activityStartDate: activityStartDate)

        Group {
            if let image = PetAssets.spritesheetImage(for: pack) {
                if let schedule {
                    TimelineView(schedule) { context in
                        spriteCanvas(image: image, track: track, date: context.date)
                    }
                } else {
                    spriteCanvas(image: image, track: Self.track(named: PetTrackName.idle.rawValue), date: activityStartDate)
                }
            }
        }
        .frame(width: renderSize.width, height: renderSize.height)
        .accessibilityHidden(true)
    }

    private func spriteCanvas(image cgImage: CGImage, track: PetAnimationTrack, date: Date) -> some View {
        let frame = track.frame(at: elapsedDuration(at: date)).spriteIndex
        return Canvas { context, size in
            let column = frame % PetSpriteGrid.columns
            let row = frame / PetSpriteGrid.columns
            let sourceRect = PetSpriteGrid.rect(row: row, column: column)
            guard let cropped = cgImage.cropping(to: sourceRect) else {
                return
            }

            context.withCGContext { cgContext in
                cgContext.interpolationQuality = .none
                // CGContext draws with a bottom-left origin inside Canvas's
                // flipped top-left space; without this the sprite renders
                // upside down.
                cgContext.translateBy(x: 0, y: size.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.draw(cropped, in: CGRect(origin: .zero, size: size))
            }
        }
    }

    private func elapsedDuration(at date: Date) -> Duration {
        .milliseconds(max(0, Int((date.timeIntervalSince(activityStartDate) * 1_000).rounded(.down))))
    }

    private static func track(named name: String) -> PetAnimationTrack {
        if name == PetTrackName.idle.rawValue {
            return .idleAmbient()
        }
        guard let row = PetSpriteGrid.rowsByName[name] else {
            return .idleAmbient()
        }
        return .appState(row: row)
    }
}

private struct PetFrameTimelineSchedule: TimelineSchedule {
    let track: PetAnimationTrack
    let activityStartDate: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> PetFrameTimelineEntries {
        PetFrameTimelineEntries(
            track: track,
            activityStartDate: activityStartDate,
            nextDate: startDate
        )
    }
}

private struct PetFrameTimelineEntries: Sequence, IteratorProtocol {
    let track: PetAnimationTrack
    let activityStartDate: Date
    var nextDate: Date
    var finished = false

    mutating func next() -> Date? {
        // A track with no next boundary (single frame, or a finished one-shot)
        // gets exactly one draw and then ends the schedule; re-emitting the
        // same date would spin TimelineView's entry consumption.
        guard !finished else {
            return nil
        }
        let emitted = nextDate
        let elapsed = Duration.milliseconds(Swift.max(0, Int((emitted.timeIntervalSince(activityStartDate) * 1_000).rounded(.down))))
        guard let nextBoundary = track.frame(at: elapsed).nextBoundary else {
            finished = true
            return emitted
        }

        let boundaryDate = activityStartDate.addingTimeInterval(nextBoundary.secondsValue)
        nextDate = boundaryDate > emitted
            ? boundaryDate
            : emitted.addingTimeInterval(0.001)
        return emitted
    }
}

private extension Duration {
    var secondsValue: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
