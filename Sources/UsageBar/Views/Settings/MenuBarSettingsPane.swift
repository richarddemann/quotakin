import SwiftUI
import UsageCore

struct MenuBarSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var petChooserSelection: PetChooserSelection?

    var body: some View {
        Form {
            MenuBarProviderSettingsSection(model: model)

            Section {
                MenuBarMetricPicker(
                    selectedMetrics: model.preferences.menuBarMetrics,
                    disabledMetrics: model.disabledMenuBarMetrics,
                    quotaDisplayMode: model.preferences.quotaDisplayMode,
                    onSetMetric: { metric, isEnabled in
                        model.setMetric(metric, isEnabled: isEnabled)
                    },
                    onMoveMetricUp: { metric in
                        model.moveMetricUp(metric)
                    },
                    onMoveMetricDown: { metric in
                        model.moveMetricDown(metric)
                    }
                )
            } header: {
                Text("Metrics")
            }

            MenuBarQuotaSettingsSection(model: model)
            MenuBarPetSettingsSection(model: model) { provider in
                petChooserSelection = PetChooserSelection(provider: provider)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $petChooserSelection) { selection in
            PetSelectorView(
                provider: selection.provider,
                preferences: model.preferences,
                onCancel: { petChooserSelection = nil },
                onSelect: { updated in
                    model.preferences = updated
                    petChooserSelection = nil
                }
            )
        }
    }
}

private struct PetChooserSelection: Identifiable {
    let provider: Provider

    var id: Provider { provider }
}
