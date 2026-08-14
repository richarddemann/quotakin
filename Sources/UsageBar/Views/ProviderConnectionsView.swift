import SwiftUI
import UsageCore

struct AccountCheckControlsPresentation: Equatable {
    static let stopDetail = "Stops future account quota requests. Local history keeps updating, and saved account quota may remain visible until its current window expires."

    let isAuthorized: Bool

    var showsStopAction: Bool { isAuthorized }
}

struct ProviderConnectionsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDescriptor: ProviderOnboardingDescriptor?

    var body: some View {
        Form {
            Section {
                ForEach(ProviderOnboardingDescriptor.all) { descriptor in
                    providerRow(descriptor)
                }
            } header: {
                Text("Providers")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $selectedDescriptor) { descriptor in
            ProviderSetupSheet(model: model, descriptor: descriptor)
        }
    }

    private func providerRow(_ descriptor: ProviderOnboardingDescriptor) -> some View {
        let presentation = presentation(for: descriptor.provider)

        return Button {
            selectedDescriptor = descriptor
        } label: {
            HStack(spacing: Space.m) {
                ProviderIconView(provider: descriptor.provider, size: 30)

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(descriptor.provider.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(presentation.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Space.m)

                ConnectionStatusLabel(
                    title: presentation.statusTitle,
                    visualState: presentation.connectionVisualState,
                    font: .callout.weight(.medium)
                )

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, Space.xs)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage \(descriptor.provider.displayName) connection")
        .accessibilityValue("\(presentation.statusTitle), \(presentation.sourceTitle)")
    }

    private func presentation(for provider: Provider) -> ProviderOnboardingPresentation {
        let summary = model.providerSummaries.first { $0.provider == provider }
            ?? ProviderSummary(provider: provider, tokens: [], quota: [], state: .unavailable)
        return ProviderOnboardingPresentation(
            summary: summary,
            connectionReport: model.providerConnectionReports[provider],
            now: Date(),
            accountChecksAuthorized: model.preferences.accountQuotaConsents.contains(provider)
        )
    }
}

private struct ConnectionStatusLabel: View {
    let title: String
    let visualState: ProviderConnectionVisualState
    let font: Font

    var body: some View {
        Label(title, systemImage: visualState.systemImage)
            .font(font)
            .foregroundStyle(visualState.color)
    }
}

private extension ProviderConnectionVisualState {
    var systemImage: String {
        switch self {
        case .verifiedAccount:
            "checkmark.circle.fill"
        case .localOnly:
            "desktopcomputer"
        case .pausedOrStale:
            "clock"
        case .needsAttention:
            "exclamationmark.circle.fill"
        case .unverified:
            "circle"
        }
    }

    var color: Color {
        switch self {
        case .verifiedAccount:
            .green
        case .needsAttention:
            .orange
        case .localOnly, .pausedOrStale, .unverified:
            .secondary
        }
    }
}

private struct ProviderSetupSheet: View {
    @ObservedObject var model: AppModel
    let descriptor: ProviderOnboardingDescriptor

    @Environment(\.dismiss) private var dismiss

    private var report: ProviderConnectionReport? {
        model.providerConnectionReports[descriptor.provider]
    }

    private var accountChecksAuthorized: Bool {
        model.preferences.accountQuotaConsents.contains(descriptor.provider)
    }

    private var accountCheckControls: AccountCheckControlsPresentation {
        AccountCheckControlsPresentation(isAuthorized: accountChecksAuthorized)
    }

    private var presentation: ProviderOnboardingPresentation {
        let summary = model.providerSummaries.first { $0.provider == descriptor.provider }
            ?? ProviderSummary(provider: descriptor.provider, tokens: [], quota: [], state: .unavailable)
        return ProviderOnboardingPresentation(
            summary: summary,
            connectionReport: report,
            now: Date(),
            accountChecksAuthorized: accountChecksAuthorized
        )
    }

    private var signInState: ProviderSignInState? {
        model.providerSignInStates[descriptor.provider]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header
                    connectionSummary
                    if !presentation.isConnectionEstablished,
                       report?.state != .rateLimited,
                       accountChecksAuthorized || report?.state != .connected {
                        guidedConnectionFlow
                    }
                    fallbackSection
                }
                .padding(Space.l)
            }

            Divider()

            setupFooter
            .padding(Space.m)
        }
        .frame(
            minWidth: 400,
            idealWidth: 440,
            maxWidth: 600,
            minHeight: 300,
            idealHeight: preferredSheetHeight,
            maxHeight: 640
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.m) {
            ProviderIconView(provider: descriptor.provider, size: 38)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(descriptor.provider.displayName)
                    .font(.title2.weight(.semibold))
                Text(descriptor.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSummary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    ConnectionStatusLabel(
                        title: presentation.statusTitle,
                        visualState: presentation.connectionVisualState,
                        font: .headline
                    )
                    Spacer()
                    Text(presentation.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Connection", value: presentation.connectionSourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let report {
                    LabeledContent(
                        "Last checked",
                        value: report.checkedAt.formatted(date: .omitted, time: .standard)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let report,
                   model.manualConnectionCheckTimestamps[descriptor.provider] == report.checkedAt {
                    Label(checkResultTitle(for: report), systemImage: checkResultSymbol(for: report))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if accountCheckControls.showsStopAction {
                    Divider()
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(AccountCheckControlsPresentation.stopDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Stop Account Checks") {
                            Task {
                                await model.stopAccountChecks(for: descriptor.provider)
                            }
                        }
                        .disabled(
                            model.isRefreshing
                                || model.checkingProviders.contains(descriptor.provider)
                                || signInState?.isActive == true
                        )
                    }
                }
            }
            .padding(Space.xs)
        }
    }

    private var guidedConnectionFlow: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(signInState == nil ? "Connect" : "Connection progress")
                .font(.headline)
            ForEach(Array(descriptor.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: Space.s) {
                    stepIndicator(index)
                    Text(step)
                        .font(.callout)
                }
            }
            if let signInState {
                HStack(spacing: Space.s) {
                    if signInState.isActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: signInStateSymbol(signInState))
                            .foregroundStyle(signInStateColor(signInState))
                    }
                    Text(signInState.title)
                        .font(.callout.weight(.medium))
                }
                .padding(.top, Space.xs)

                if case .waitingForBrowser = signInState {
                    Text("Your default browser should open automatically. If it does not, cancel and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let details = signInState.details, !details.isEmpty {
                    DisclosureGroup("Show details") {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.xs)
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func stepIndicator(_ index: Int) -> some View {
        switch stepState(index) {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 20, height: 20)
        case .current:
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20)
        case .pending:
            Text("\(index + 1)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.quaternary, in: Circle())
        }
    }

    private func stepState(_ index: Int) -> ConnectionStepState {
        guard let signInState else {
            return .pending
        }
        let currentStep: Int
        switch signInState {
        case .launching, .waitingForBrowser:
            currentStep = 0
        case .authorizingAccess:
            currentStep = max(0, descriptor.steps.count - 2)
        case .verifying:
            currentStep = max(0, descriptor.steps.count - 1)
        case .connected:
            return .complete
        case .permissionRequired:
            let permissionStep = max(0, descriptor.steps.count - 2)
            if index < permissionStep { return .complete }
            return index == permissionStep ? .warning : .pending
        case .failed:
            return index == 0 ? .warning : .pending
        }
        if index < currentStep { return .complete }
        if index == currentStep { return .current }
        return .pending
    }

    private func signInStateSymbol(_ state: ProviderSignInState) -> String {
        switch state {
        case .connected:
            return "checkmark.circle.fill"
        case .permissionRequired, .failed:
            return "exclamationmark.triangle.fill"
        case .launching, .waitingForBrowser, .authorizingAccess, .verifying:
            return "circle"
        }
    }

    private func signInStateColor(_ state: ProviderSignInState) -> Color {
        switch state {
        case .connected:
            return .green
        case .permissionRequired, .failed:
            return .orange
        case .launching, .waitingForBrowser, .authorizingAccess, .verifying:
            return .secondary
        }
    }

    @ViewBuilder
    private var fallbackSection: some View {
        if let installAction = descriptor.fallbackInstallAction {
            DisclosureGroup("Local fallback") {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Optional. Captures quota from interactive Claude Code sessions on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(installAction.title) {
                            perform(installAction)
                        }
                        .disabled(model.isRefreshing)

                        if !descriptor.fallbackMaintenanceActions.isEmpty {
                            Menu("Maintenance") {
                                ForEach(descriptor.fallbackMaintenanceActions) { action in
                                    Button(action.title) {
                                        perform(action)
                                    }
                                }
                            }
                            .disabled(model.isRefreshing)
                        }
                    }
                }
                .padding(.top, Space.s)
            }
            .font(.callout)
        }
    }

    private var setupFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                doneButton
                Spacer()
                connectionActions
            }
            VStack(alignment: .trailing, spacing: Space.s) {
                connectionActions
                doneButton
            }
        }
    }

    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(signInState?.isActive == true)
    }

    @ViewBuilder
    private var connectionActions: some View {
        if let signInState, signInState.isActive {
            HStack(spacing: Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text(signInState.title)
                    .foregroundStyle(.secondary)
                if signInState.canCancel {
                    Button("Cancel") {
                        model.cancelSignIn(for: descriptor.provider)
                    }
                }
            }
        } else if case .permissionRequired = signInState {
            Button("Grant Access…") {
                perform(ProviderSetupActionDescriptor(
                    kind: .authorizeClaudeAccount,
                    title: "Grant Access…"
                ))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else if model.checkingProviders.contains(descriptor.provider) {
            HStack(spacing: Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        } else if !accountChecksAuthorized, report?.state == .connected {
            Button("Check Account") {
                perform(descriptor.checkAction)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRefreshing)
        } else if presentation.isConnectionEstablished {
            Button("Check Now") {
                perform(descriptor.checkAction)
            }
            .disabled(model.isRefreshing)
        } else if presentation.shouldOfferAccountCheck {
            Button("Check Now") {
                perform(descriptor.checkAction)
            }
            .disabled(model.isRefreshing)
        } else if report?.state == .rateLimited {
            Button("Try Again") {
                perform(descriptor.checkAction)
            }
            .disabled(model.isRefreshing)
        } else if let action = descriptor.primaryAction(for: report) {
            Button(action.title) {
                perform(action)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRefreshing)
        }
    }

    private var preferredSheetHeight: CGFloat {
        if presentation.isConnectionEstablished || report?.state == .rateLimited {
            return 340
        }
        return 460
    }

    private func checkResultTitle(for report: ProviderConnectionReport) -> String {
        switch report.state {
        case .connected:
            return "Account quota connected."
        case .authenticationRequired:
            return "Sign-in or authorization is required."
        case .permissionRequired:
            return "Account access was denied."
        case .rateLimited:
            return "Account check was temporarily throttled."
        case .unavailable:
            return "Account check failed."
        }
    }

    private func checkResultSymbol(for report: ProviderConnectionReport) -> String {
        switch report.state {
        case .connected:
            return "checkmark.circle"
        case .authenticationRequired, .permissionRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .rateLimited:
            return "clock.badge.exclamationmark"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private func perform(_ action: ProviderSetupActionDescriptor) {
        Task {
            await model.performSetupAction(action.kind)
        }
    }
}

private enum ConnectionStepState {
    case complete
    case current
    case pending
    case warning
}
