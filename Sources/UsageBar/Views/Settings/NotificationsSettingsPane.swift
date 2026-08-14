import AppKit
import SwiftUI
import UsageCore

struct NotificationsSettingsPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            authorizationSection

            Section {
                Toggle("Usage thresholds", isOn: kindBinding(.thresholdCrossed))
                Toggle("Window resets", isOn: kindBinding(.windowReset))
                Toggle("Limit forecast", isOn: kindBinding(.atRiskPrediction))
            } header: {
                Text("Alerts")
            }

            Section {
                thresholdRow(window: .session, title: "5-hour window")
                thresholdRow(window: .weekly, title: "Weekly window")
            } header: {
                Text("Thresholds")
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refreshNotificationAuthorizationState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }
            Task {
                await model.refreshNotificationAuthorizationState()
            }
        }
    }

    @ViewBuilder
    private var authorizationSection: some View {
        Section {
            LabeledContent("macOS notifications") {
                Text(authorizationLabel)
                    .foregroundStyle(.secondary)
            }
            if model.notificationAuthorizationState == .blocked {
                Text("Notifications are blocked in macOS, so Quotakin cannot deliver alerts.")
                Button("Open System Settings…") {
                    openNotificationSettings()
                }
                .accessibilityHint("Opens macOS notification settings for Quotakin")
            }
        } header: {
            Text("Permission")
        }
    }

    private var authorizationLabel: String {
        switch model.notificationAuthorizationState {
        case .allowed:
            "Allowed"
        case .notRequested:
            "Not requested"
        case .blocked:
            "Blocked"
        case .unknown:
            "Unknown"
        }
    }

    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
    private static let legacyNotificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications"
    )!
    private static let systemSettingsURL = URL(
        fileURLWithPath: "/System/Applications/System Settings.app"
    )

    private func openNotificationSettings() {
        if NSWorkspace.shared.open(Self.notificationSettingsURL) {
            return
        }
        if NSWorkspace.shared.open(Self.legacyNotificationSettingsURL) {
            return
        }
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }

    private func kindBinding(_ kind: QuotaNotificationKind) -> Binding<Bool> {
        Binding(
            get: { model.preferences.notificationPreferences.isEnabled(kind) },
            set: { isOn in
                var kinds = model.preferences.notificationPreferences.enabledKinds.filter { $0 != kind }
                if isOn {
                    kinds.append(kind)
                    if kind == .thresholdCrossed,
                       model.preferences.notificationPreferences.thresholdsByWindow.isEmpty {
                        model.preferences.notificationPreferences.thresholdsByWindow = [
                            .session: Self.defaultThresholds,
                            .weekly: Self.defaultThresholds
                        ]
                    }
                }
                model.preferences.notificationPreferences.enabledKinds = kinds
            }
        )
    }

    static let defaultThresholds = [75.0, 90.0]

    private func thresholdRow(window: QuotaWindow, title: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: Space.xs) {
                ForEach([50.0, 75.0, 90.0], id: \.self) { threshold in
                    Toggle(
                        String(format: "%.0f%%", threshold),
                        isOn: thresholdBinding(window: window, threshold: threshold)
                    )
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(!model.preferences.notificationPreferences.isEnabled(.thresholdCrossed))
                }
            }
        }
    }

    private func thresholdBinding(window: QuotaWindow, threshold: Double) -> Binding<Bool> {
        Binding(
            get: {
                model.preferences.notificationPreferences.thresholds(for: window).contains(threshold)
            },
            set: { isOn in
                var byWindow = model.preferences.notificationPreferences.thresholdsByWindow
                var values = (byWindow[window] ?? []).filter { $0 != threshold }
                if isOn {
                    values.append(threshold)
                }
                byWindow[window] = values.sorted()
                model.preferences.notificationPreferences.thresholdsByWindow = byWindow
            }
        )
    }
}
