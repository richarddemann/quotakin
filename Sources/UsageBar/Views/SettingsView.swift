import SwiftUI
import UsageCore

enum SettingsDestination: String, CaseIterable, Identifiable {
    case display
    case alerts
    case connections
    case advanced

    var id: Self { self }

    static let defaultDestination: Self = .display

    var title: String {
        switch self {
        case .display: "Display"
        case .alerts: "Alerts"
        case .connections: "Connections"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "menubar.rectangle"
        case .alerts: "bell"
        case .connections: "link"
        case .advanced: "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var automaticallyChecksForAppUpdates: Binding<Bool>?
    var checkForUpdates: (() -> Void)?

    init(
        model: AppModel,
        automaticallyChecksForAppUpdates: Binding<Bool>? = nil,
        checkForUpdates: (() -> Void)? = nil
    ) {
        self.model = model
        self.automaticallyChecksForAppUpdates = automaticallyChecksForAppUpdates
        self.checkForUpdates = checkForUpdates
    }

    var body: some View {
        TabView {
            Tab(SettingsDestination.display.title, systemImage: SettingsDestination.display.systemImage) {
                MenuBarSettingsPane(model: model)
                    .settingsPaneFrame()
            }

            Tab(SettingsDestination.alerts.title, systemImage: SettingsDestination.alerts.systemImage) {
                NotificationsSettingsPane(model: model)
                    .settingsPaneFrame()
            }

            Tab(SettingsDestination.connections.title, systemImage: SettingsDestination.connections.systemImage) {
                ProviderConnectionsView(model: model)
                    .settingsPaneFrame()
            }

            Tab(SettingsDestination.advanced.title, systemImage: SettingsDestination.advanced.systemImage) {
                GeneralSettingsPane(
                    model: model,
                    automaticallyChecksForAppUpdates: automaticallyChecksForAppUpdates,
                    checkForUpdates: checkForUpdates
                )
                    .settingsPaneFrame()
            }
        }
        .settingsPaneFrame()
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .alert(
            model.helperConfirmation?.kind.title ?? "",
            isPresented: helperConfirmationIsPresented,
            presenting: model.helperConfirmation
        ) { confirmation in
            Button(confirmation.kind.buttonTitle) {
                Task {
                    await model.confirmHelperAction(confirmation.kind)
                }
            }
            Button("Cancel", role: .cancel) {
                model.cancelHelperConfirmation()
            }
        } message: { confirmation in
            Text(confirmation.kind.message)
        }
    }

    private var helperConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { model.helperConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelHelperConfirmation()
                }
            }
        )
    }
}

private extension View {
    func settingsPaneFrame() -> some View {
        frame(width: SettingsLayout.windowWidth)
            .frame(
                minHeight: SettingsLayout.minimumHeight,
                maxHeight: SettingsLayout.maximumHeight
            )
    }
}
