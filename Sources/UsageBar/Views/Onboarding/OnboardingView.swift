import SwiftUI
import UsageCore

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = OnboardingStep.welcome

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(step: step)
                .padding(.horizontal, Space.l)
                .padding(.top, Space.l)

            Divider()
                .padding(.top, Space.m)

            Group {
                switch step {
                case .welcome:
                    OnboardingWelcomeStep()
                case .providers:
                    OnboardingProvidersStep(model: model)
                case .menuBar:
                    OnboardingMenuBarStep(model: model)
                case .finished:
                    OnboardingFinishedStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
        }
        .frame(
            minWidth: 520,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 420,
            idealHeight: 560,
            maxHeight: .infinity
        )
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .finished {
                Button("Back") {
                    step = step.previous
                }
            }

            Spacer()

            if step == .finished {
                Button("Start Using Quotakin") {
                    model.completeOnboarding()
                    dismissWindow(id: OnboardingWindow.id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .welcome ? "Get Started" : "Continue") {
                    step = step.next
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case providers
    case menuBar
    case finished

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .providers: "Providers"
        case .menuBar: "Menu Bar"
        case .finished: "All Set"
        }
    }

    var next: OnboardingStep {
        OnboardingStep(rawValue: rawValue + 1) ?? .finished
    }

    var previous: OnboardingStep {
        OnboardingStep(rawValue: rawValue - 1) ?? .welcome
    }
}

private struct OnboardingHeader: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "chart.bar.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control))

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Quotakin")
                    .font(.headline)
                Text(step.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: Space.xs) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: item == step ? 30 : 12, height: 5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count): \(step.title)")
        }
    }
}

private struct OnboardingWelcomeStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: Space.xs) {
                    Text("Your AI capacity, one glance away")
                        .font(.largeTitle.weight(.semibold))
                    Text("Quotakin keeps Claude and Codex usage visible without putting another app in your Dock.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                }

                VStack(alignment: .leading, spacing: Space.m) {
                    WelcomeFeature(
                        symbol: "menubar.rectangle",
                        title: "Always nearby",
                        detail: "Lives quietly in the menu bar"
                    )
                    WelcomeFeature(
                        symbol: "lock.shield",
                        title: "Local usage history",
                        detail: "Reads usage metadata already on this Mac"
                    )
                    WelcomeFeature(
                        symbol: "arrow.clockwise",
                        title: "Current limits",
                        detail: "Optional account checks are read-only"
                    )
                    WelcomeFeature(
                        symbol: "network",
                        title: "Public service status",
                        detail: "Checks provider status pages without account credentials"
                    )
                }
                .frame(maxWidth: 500, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(Space.l)
        }
    }
}

private struct WelcomeFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingProvidersStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Choose what you use")
                        .font(.title.weight(.semibold))
                    Text("You can change providers and connections later in Settings.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: Space.m) {
                    SourceExplanation(
                        symbol: "macbook",
                        title: "Local history",
                        detail: "Past token activity found on this Mac. It cannot tell you your current account-wide allowance."
                    )
                    Divider()
                    SourceExplanation(
                        symbol: "person.crop.circle.badge.checkmark",
                        title: "Account quota",
                        detail: "Current provider-reported limits across the account. Quotakin’s checks are optional and read-only."
                    )
                }

                VStack(spacing: 0) {
                    ForEach(Array(ProviderOnboardingDescriptor.all.enumerated()), id: \.element.id) { index, descriptor in
                        OnboardingProviderRow(model: model, descriptor: descriptor)
                        if index < ProviderOnboardingDescriptor.all.count - 1 {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }

                Label(
                    "Quotakin’s checks are read-only. Connect opens the provider’s login and may create or update its saved sign-in.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)
        }
    }
}

private struct SourceExplanation: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingProviderRow: View {
    @ObservedObject var model: AppModel
    let descriptor: ProviderOnboardingDescriptor

    private var isEnabled: Bool {
        model.preferences.providers.contains(descriptor.provider)
    }

    private var report: ProviderConnectionReport? {
        model.providerConnectionReports[descriptor.provider]
    }

    private var isBusy: Bool {
        model.checkingProviders.contains(descriptor.provider)
            || model.providerSignInStates[descriptor.provider]?.isActive == true
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                providerToggle
                Spacer(minLength: Space.m)
                connectionControl
            }

            VStack(alignment: .leading, spacing: Space.s) {
                providerToggle
                HStack {
                    Spacer()
                    connectionControl
                }
            }
        }
        .padding(.vertical, Space.m)
    }

    private var providerToggle: some View {
        Toggle(isOn: Binding(
            get: { isEnabled },
            set: { model.setProvider(descriptor.provider, isEnabled: $0) }
        )) {
            HStack(spacing: Space.s) {
                ProviderIconView(provider: descriptor.provider, size: 30)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(descriptor.provider.displayName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var connectionControl: some View {
        if isBusy {
            HStack(spacing: Space.xs) {
                ProgressView()
                    .controlSize(.small)
                Text(model.providerSignInStates[descriptor.provider]?.title ?? "Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let action = connectionAction {
            Button(action.title) {
                // Consent for an account probe is recorded inside this explicit
                // action path. The provider visibility toggle above never opts in.
                Task { await model.performSetupAction(action.kind) }
            }
            .disabled(!isEnabled)
        }
    }

    private var connectionAction: ProviderSetupActionDescriptor? {
        switch report?.state {
        case .connected, .rateLimited:
            descriptor.checkAction
        case .authenticationRequired, .permissionRequired, .unavailable, nil:
            descriptor.primaryAction(for: report) ?? descriptor.checkAction
        }
    }

    private var subtitle: String {
        guard isEnabled else {
            return "Not shown"
        }
        if let state = model.providerSignInStates[descriptor.provider] {
            return state.title
        }
        guard report != nil else {
            return "Shown in Quotakin · account connection optional"
        }
        let summary = model.providerSummaries.first { $0.provider == descriptor.provider }
            ?? ProviderSummary(provider: descriptor.provider, tokens: [], quota: [], state: .unavailable)
        let presentation = ProviderOnboardingPresentation(
            summary: summary,
            connectionReport: report,
            now: Date(),
            accountChecksAuthorized: model.preferences.accountQuotaConsents.contains(descriptor.provider)
        )
        return "\(presentation.statusTitle) · \(presentation.sourceTitle)"
    }
}

private struct OnboardingMenuBarStep: View {
    @ObservedObject var model: AppModel

    private var selectedStyle: OnboardingMenuBarStyle? {
        OnboardingMenuBarStyle.matching(preferences: model.preferences)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Choose a compact menu-bar style")
                        .font(.title.weight(.semibold))
                    Text("Keep it quiet, or show the number you check most. More metrics are available in Settings.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(OnboardingMenuBarStyle.allCases.enumerated()), id: \.element.id) { index, style in
                        Button {
                            apply(style)
                        } label: {
                            HStack(spacing: Space.m) {
                                Image(systemName: selectedStyle == style ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedStyle == style ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(style.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(style.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(style.preview)
                                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .padding(Space.m)
                            .background(selectedStyle == style ? Color.accentColor.opacity(0.08) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title)
                        .accessibilityValue(selectedStyle == style ? "Selected" : "Not selected")
                        .accessibilityHint(style.detail)
                        .accessibilityAddTraits(selectedStyle == style ? .isSelected : [])

                        if index < OnboardingMenuBarStyle.allCases.count - 1 {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            }
            .padding(Space.l)
        }
    }

    private func apply(_ style: OnboardingMenuBarStyle) {
        for metric in MenuBarMetric.allCases {
            model.setMetric(metric, isEnabled: style.metrics.contains(metric))
        }
    }
}

private enum OnboardingMenuBarStyle: String, CaseIterable, Identifiable {
    case icons
    case session
    case sessionAndReset

    var id: String { rawValue }

    static func matching(preferences: UserPreferences) -> OnboardingMenuBarStyle? {
        let selectedMetrics = Set(preferences.menuBarMetrics)
        return allCases.first { $0.metrics == selectedMetrics }
    }

    var title: String {
        switch self {
        case .icons: "Provider icons"
        case .session: "Session remaining"
        case .sessionAndReset: "Session and reset"
        }
    }

    var detail: String {
        switch self {
        case .icons: "The smallest footprint; open Quotakin for details."
        case .session: "See current session capacity without opening the popover."
        case .sessionAndReset: "Add the reset countdown for a little more context."
        }
    }

    var preview: String {
        switch self {
        case .icons: "◆  ●"
        case .session: "◆  72%"
        case .sessionAndReset: "◆  72%  1h 24m"
        }
    }

    var metrics: Set<MenuBarMetric> {
        switch self {
        case .icons: []
        case .session: [.sessionPercentage]
        case .sessionAndReset: [.sessionPercentage, .resetCountdown]
        }
    }
}

private struct OnboardingFinishedStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 78, weight: .light))
                        .foregroundStyle(.primary)
                    Image(systemName: "arrow.up.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .offset(x: 22, y: -12)
                }
                .accessibilityHidden(true)

                VStack(spacing: Space.xs) {
                    Text("Quotakin lives in your menu bar")
                        .font(.largeTitle.weight(.semibold))
                    Text("Look at the top-right of your screen. Click the Quotakin item anytime to see quota, refresh data, or open Settings.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                }

                Label("No Dock icon, no window to keep open", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(Space.l)
        }
    }
}
