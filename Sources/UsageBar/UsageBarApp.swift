import SwiftUI

@main
struct QuotakinApp: App {
    @StateObject private var model = AppModel.live()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
                .task {
                    await model.start()
                }
        } label: {
            MenuBarLabel(
                summaries: model.providerSummaries,
                preferences: model.preferences,
                formatter: model.formatter
            )
            .handlesOnboardingPresentation(model: model)
            .task {
                await model.start()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Usage", id: "history") {
            HistoryView(model: model)
                .frame(minWidth: 620, minHeight: 640)
                .task {
                    await model.start()
                }
        }
        .defaultSize(width: 1060, height: 780)
        .windowResizability(.contentMinSize)

        Window(OnboardingWindow.title, id: OnboardingWindow.id) {
            OnboardingView(model: model)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
                .task {
                    await model.start()
                }
        }
        .defaultSize(width: SettingsLayout.windowWidth, height: 620)
        // Respect SettingsView's fixed horizontal bounds while its infinite
        // maximum height keeps vertical resizing available.
        .windowResizability(.contentSize)
    }
}
