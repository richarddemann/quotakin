import SwiftUI
import UsageCore

struct MenuBarProviderSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            ForEach(Provider.allCases, id: \.self) { provider in
                Toggle(isOn: Binding(
                    get: { model.preferences.providers.contains(provider) },
                    set: { model.setProvider(provider, isEnabled: $0) }
                )) {
                    HStack(spacing: Space.xs) {
                        ProviderIconView(provider: provider, size: 20)
                        Text(provider.displayName)
                    }
                }
            }
        } header: {
            Text("Visible Providers")
        } footer: {
            Text("Visibility only. Account checks are managed in Connections.")
        }
    }
}

struct MenuBarQuotaSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Picker("Quota display", selection: Binding(
                get: { model.preferences.quotaDisplayMode },
                set: { model.preferences.quotaDisplayMode = $0 }
            )) {
                ForEach(QuotaDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Quota")
        }
    }
}

struct MenuBarPetSettingsSection: View {
    @ObservedObject var model: AppModel
    let onChoosePet: (Provider) -> Void

    var body: some View {
        Section {
            Toggle("Show quota pets", isOn: Binding(
                get: { model.preferences.petModeEnabled },
                set: { model.preferences.petModeEnabled = $0 }
            ))

            if model.preferences.petModeEnabled {
                Toggle("Show provider names with pets", isOn: Binding(
                    get: { model.preferences.showProviderNamesInPetMode },
                    set: { model.preferences.showProviderNamesInPetMode = $0 }
                ))

                ForEach(visibleProviders, id: \.self) { provider in
                    PetSelectorButton(provider: provider, preferences: model.preferences) {
                        onChoosePet(provider)
                    }
                }
            }
        } header: {
            Text("Pets")
        }
    }

    private var visibleProviders: [Provider] {
        Provider.allCases.filter(model.preferences.providers.contains)
    }
}
