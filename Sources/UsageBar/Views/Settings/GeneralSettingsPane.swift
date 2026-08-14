import AppKit
import SwiftUI
import UsageCore

enum RefreshMode: String, CaseIterable, Identifiable {
    case automatic
    case manual
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Manual"
        case .custom: "Custom"
        }
    }
}

struct RefreshSettingsPresentation {
    static func mode(
        localUsage: RefreshProfile,
        accountQuota: LiveQuotaRefreshInterval
    ) -> RefreshMode {
        switch (localUsage, accountQuota) {
        case (.efficient, .oneMinute): .automatic
        case (.manual, .manual): .manual
        default: .custom
        }
    }

    static func preferences(
        for mode: RefreshMode
    ) -> (localUsage: RefreshProfile, accountQuota: LiveQuotaRefreshInterval)? {
        switch mode {
        case .automatic: (.efficient, .oneMinute)
        case .manual: (.manual, .manual)
        case .custom: nil
        }
    }

    static func localUsageTitle(_ profile: RefreshProfile) -> String {
        switch profile {
        case .realTime: "File changes + every 5 min"
        case .efficient: "File changes + every 15 min"
        case .responsive: "File changes + every 10 min"
        case .manual: "Manual"
        }
    }

    static func accountStatus(
        checksEnabled: Bool,
        report: ProviderConnectionReport?
    ) -> String {
        guard checksEnabled else {
            return "Not enabled"
        }
        guard let report else {
            return "Waiting for first check"
        }
        let state = switch report.state {
        case .connected: "Connected"
        case .authenticationRequired: "Sign-in required"
        case .permissionRequired: "Permission required"
        case .rateLimited: "Temporarily throttled"
        case .unavailable: "Unavailable"
        }
        let time = report.checkedAt.formatted(date: .omitted, time: .shortened)
        return "\(state) · checked \(time)"
    }
}

struct GeneralSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var showsCustomRefreshSettings = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Menu(refreshMode.title) {
                        ForEach([RefreshMode.automatic, .manual]) { mode in
                            Button(mode.title) {
                                if let pair = RefreshSettingsPresentation.preferences(for: mode) {
                                    model.setRefreshSettings(
                                        localUsage: pair.localUsage,
                                        accountQuota: pair.accountQuota
                                    )
                                }
                            }
                        }
                    }
                } label: {
                    UpdateInfoLabel(detail: refreshModeDetail)
                }

                DisclosureGroup("Customize", isExpanded: $showsCustomRefreshSettings) {
                    Picker("Account quota", selection: Binding(
                        get: { model.preferences.liveQuotaRefreshInterval },
                        set: { model.setLiveQuotaRefreshInterval($0) }
                    )) {
                        ForEach(LiveQuotaRefreshInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    Picker("Local usage", selection: Binding(
                        get: { model.preferences.refreshProfile },
                        set: { model.setRefreshProfile($0) }
                    )) {
                        ForEach(RefreshProfile.allCases, id: \.self) { profile in
                            Text(RefreshSettingsPresentation.localUsageTitle(profile)).tag(profile)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Local usage", value: localUsageStatus)
                ForEach(enabledAccountProviders, id: \.self) { provider in
                    LabeledContent(
                        "\(provider.displayName) account",
                        value: RefreshSettingsPresentation.accountStatus(
                            checksEnabled: model.preferences.accountQuotaConsents.contains(provider),
                            report: model.providerConnectionReports[provider]
                        )
                    )
                }
            } header: {
                Text("Update Status")
            }

            Section {
                Button("Show Welcome Guide…") {
                    model.showOnboarding()
                }
                .accessibilityHint("Opens the Quotakin welcome and setup guide")
            } header: {
                Text("Setup")
            }

            Section {
                Button("Open Pet Packs Folder") {
                    openPetPacksFolder()
                }
                .accessibilityHint("Opens the custom pet packs folder in Finder")
            } header: {
                Text("Pet Packs")
            } footer: {
                petPacksFooter
            }

            Section {
                Button("Report a Bug…") {
                    BugReporter.openPrefilledIssue()
                }
                .accessibilityHint("Opens a prefilled GitHub issue in your browser")
                LabeledContent("Version", value: "Quotakin \(appVersion)")
            } header: {
                Text("Support")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if refreshMode == .custom {
                showsCustomRefreshSettings = true
            }
        }
    }

    private var refreshMode: RefreshMode {
        RefreshSettingsPresentation.mode(
            localUsage: model.preferences.refreshProfile,
            accountQuota: model.preferences.liveQuotaRefreshInterval
        )
    }

    private var refreshModeDetail: String {
        switch refreshMode {
        case .automatic:
            "Recommended. Watches local usage files, performs a 15-minute safety scan, and checks connected accounts up to once a minute."
        case .manual:
            "Updates only when you choose Refresh or launch Quotakin."
        case .custom:
            "Uses the account and local schedules under Customize."
        }
    }

    private var enabledAccountProviders: [Provider] {
        Provider.allCases.filter(model.preferences.accountQuotaConsents.contains)
    }

    private var localUsageStatus: String {
        guard let lastRefreshAt = model.lastLocalUsageRefreshAt else {
            return "Waiting for first refresh"
        }
        return "Updated \(lastRefreshAt.formatted(date: .omitted, time: .shortened))"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var petPacksFooter: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if !PetAssets.loaderDiagnostics.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(Array(PetAssets.loaderDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text("\(diagnostic.packDirectoryName): \(diagnostic.reason)")
                    }
                }
            }
        }
    }

    private func openPetPacksFolder() {
        let url = PetAssets.userInstalledPacksURL
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private struct UpdateInfoLabel: View {
    let detail: String

    @State private var showsDetail = false

    var body: some View {
        HStack(spacing: Space.xxs) {
            Text("Updates")
            Button {
                showsDetail.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("About updates")
            .accessibilityLabel("About updates")
            .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(width: 270, alignment: .leading)
            }
        }
    }
}
