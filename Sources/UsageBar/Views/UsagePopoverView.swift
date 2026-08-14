import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: AppModel
    private let quitAction: ApplicationQuitAction
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsAction

    init(
        model: AppModel,
        quitAction: ApplicationQuitAction = .live
    ) {
        self.model = model
        self.quitAction = quitAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(model.visibleProviderSummaries.enumerated()), id: \.element.provider) { index, summary in
                VStack(alignment: .leading, spacing: Space.s) {
                    ProviderCardView(
                        summary: summary,
                        preferences: model.preferences,
                        status: model.providerStatuses[summary.provider],
                        resetPulse: model.lastWindowResetAt[summary.provider]
                    )

                    if index < model.visibleProviderSummaries.count - 1 {
                        Divider()
                    }
                }
            }

            Divider()

            HStack(spacing: Space.xs) {
                RefreshButton(
                    isRefreshing: model.isRefreshing,
                    lastRefreshedAt: model.lastRefreshAt,
                    showsCaption: false
                ) {
                    Task {
                        await model.refreshNow()
                    }
                }

                Button {
                    openHistory()
                } label: {
                    Label("Usage Overview", systemImage: "chart.bar.xaxis")
                        .labelStyle(.iconOnly)
                }
                .help("Usage Overview")
                .accessibilityLabel("Usage Overview")

                Spacer()

                Button {
                    BugReporter.openPrefilledIssue()
                } label: {
                    Label("Report a Bug…", systemImage: "ladybug")
                        .labelStyle(.iconOnly)
                }
                .help("Report a Bug…")
                .accessibilityLabel("Report a Bug…")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings")
                .accessibilityLabel("Settings")

                Button {
                    quitAction()
                } label: {
                    Label(ApplicationQuitAction.title, systemImage: ApplicationQuitAction.systemImage)
                        .labelStyle(.iconOnly)
                }
                .help(ApplicationQuitAction.title)
                .accessibilityLabel(ApplicationQuitAction.title)
                .accessibilityHint(ApplicationQuitAction.accessibilityHint)
                .keyboardShortcut("q", modifiers: .command)
            }

            if let notice = actionableStatus {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(Space.m)
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 360)
    }

    /// Routine refresh chatter stays out of the popover; only messages the
    /// user can act on (errors, helper guidance) earn a line.
    private var actionableStatus: String? {
        let message = model.statusMessage
        let routinePrefixes = ["Last refreshed", "Refreshing usage", "Loading usage store"]
        guard !routinePrefixes.contains(where: { message.hasPrefix($0) }) else {
            return nil
        }
        return message.isEmpty ? nil : message
    }

    private func openHistory() {
        openWindow(id: "history")
        WindowFocus.bringForward(title: "Usage")
    }

    private func openSettings() {
        openSettingsAction()
        // Accessory (LSUIElement) apps don't reliably raise a freshly opened
        // window above the frontmost app; bring Settings forward explicitly.
        WindowFocus.present()
    }
}
