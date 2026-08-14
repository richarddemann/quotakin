import SwiftUI

/// The popover's refresh control. It can optionally show an "Updated Xm ago"
/// caption in surfaces where the extra status is useful. While a
/// refresh runs the arrow rotates continuously (Reduce Motion falls back to a
/// static, dimmed glyph); on completion a brief checkmark flashes and the
/// caption ticks to "just now".
struct RefreshButton: View {
    let isRefreshing: Bool
    let lastRefreshedAt: Date?
    var showsCaption = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCompletion = false
    @State private var completionTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: Space.xs) {
            Button(action: action) {
                icon
                    .frame(width: 16, height: 16)
            }
            .disabled(isRefreshing)
            .help(helpText)
            .accessibilityLabel("Refresh")
            .accessibilityValue(accessibilityValue)

            if showsCaption {
                // .everyMinute re-renders the caption so relative time stays
                // honest without a manual timer.
                TimelineView(.everyMinute) { context in
                    Text(caption(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .onChange(of: isRefreshing) { previous, current in
            guard previous, !current else { return }
            flashCompletion()
        }
        .onDisappear { completionTask?.cancel() }
    }

    @ViewBuilder
    private var icon: some View {
        if isRefreshing {
            if reduceMotion {
                // No spin under Reduce Motion: a dimmed static glyph signals work.
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            } else {
                SpinningArrow()
            }
        } else if showCompletion {
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
                .transition(.opacity)
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }

    private func flashCompletion() {
        completionTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            showCompletion = true
        }
        completionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showCompletion = false
            }
        }
    }

    private var helpText: String {
        guard let lastRefreshedAt else {
            return "Refresh"
        }
        return "Refresh — updated \(Self.relativeLabel(for: lastRefreshedAt, now: Date()))"
    }

    private var accessibilityValue: String {
        guard let lastRefreshedAt else {
            return "Not refreshed yet"
        }
        return "Updated \(Self.relativeLabel(for: lastRefreshedAt, now: Date()))"
    }

    private func caption(now: Date) -> String {
        if isRefreshing {
            return "Updating…"
        }
        guard let lastRefreshedAt else {
            return "Not refreshed yet"
        }
        return "Updated \(Self.relativeLabel(for: lastRefreshedAt, now: now))"
    }

    static func relativeLabel(for date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 {
            return "just now"
        }
        if seconds < 90 {
            return "1m ago"
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = Int((seconds / 3_600).rounded())
        if hours < 24 {
            return "\(hours)h ago"
        }
        let days = Int((seconds / 86_400).rounded())
        return "\(days)d ago"
    }
}

/// A self-contained spinning glyph. Living only while a refresh runs means its
/// `onAppear` starts the infinite rotation and its removal ends it cleanly —
/// no reverse-spin when the parent swaps back to the static icon.
private struct SpinningArrow: View {
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
