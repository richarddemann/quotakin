import Foundation

public enum RefreshProfile: String, Codable, CaseIterable, Sendable {
    case realTime
    case efficient
    case responsive
    case manual

    public var fallbackInterval: TimeInterval? {
        switch self {
        case .realTime:
            300
        case .efficient:
            900
        case .responsive:
            600
        case .manual:
            nil
        }
    }
}

public enum LiveQuotaRefreshInterval: String, Codable, CaseIterable, Sendable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case manual

    public var interval: TimeInterval? {
        switch self {
        case .oneMinute:
            60
        case .fiveMinutes:
            300
        case .fifteenMinutes:
            900
        case .manual:
            nil
        }
    }
}

public enum MenuBarMetric: String, Codable, CaseIterable, Sendable {
    case sessionPercentage
    case resetCountdown
    case weeklyPercentage
    case dailyTokens
    case weeklyTokens
    case monthlyTokens
    case estimatedMonthlyCost
}

public enum QuotaDisplayMode: String, Codable, CaseIterable, Sendable {
    case remaining
    case used

    public var label: String {
        switch self {
        case .remaining:
            "left"
        case .used:
            "used"
        }
    }

    public func percent(for snapshot: QuotaSnapshot) -> Double {
        switch self {
        case .remaining:
            snapshot.remainingPercent
        case .used:
            snapshot.clampedUsedPercent
        }
    }
}

public enum QuotaNotificationKind: String, Codable, CaseIterable, Sendable {
    case thresholdCrossed
    case windowReset
    case atRiskPrediction
}

public struct QuotaNotificationPreferences: Codable, Equatable, Sendable {
    public var enabledKinds: [QuotaNotificationKind]
    public var thresholdsByWindow: [QuotaWindow: [Double]]

    public init(
        enabledKinds: [QuotaNotificationKind] = [],
        thresholdsByWindow: [QuotaWindow: [Double]] = [:]
    ) {
        self.enabledKinds = Self.uniqueKinds(enabledKinds)
        self.thresholdsByWindow = Self.normalizedThresholdsByWindow(thresholdsByWindow)
    }

    public var isEnabled: Bool {
        !enabledKinds.isEmpty
    }

    public func isEnabled(_ kind: QuotaNotificationKind) -> Bool {
        enabledKinds.contains(kind)
    }

    public func thresholds(for window: QuotaWindow) -> [Double] {
        thresholdsByWindow[window] ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case enabledKinds
        case thresholdsByWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabledKinds: try container.decodeIfPresent(
                [QuotaNotificationKind].self,
                forKey: .enabledKinds
            ) ?? [],
            thresholdsByWindow: try container.decodeIfPresent(
                [QuotaWindow: [Double]].self,
                forKey: .thresholdsByWindow
            ) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledKinds, forKey: .enabledKinds)
        try container.encode(thresholdsByWindow, forKey: .thresholdsByWindow)
    }

    private static func uniqueKinds(_ kinds: [QuotaNotificationKind]) -> [QuotaNotificationKind] {
        var seen: Set<QuotaNotificationKind> = []
        return kinds.filter { seen.insert($0).inserted }
    }

    private static func normalizedThresholdsByWindow(
        _ thresholdsByWindow: [QuotaWindow: [Double]]
    ) -> [QuotaWindow: [Double]] {
        thresholdsByWindow.reduce(into: [:]) { result, entry in
            let thresholds = entry.value
                .filter { $0 > 0 && $0 <= 100 }
                .map { ($0 * 100).rounded() / 100 }
            let unique = Set(thresholds).sorted()
            if !unique.isEmpty {
                result[entry.key] = unique
            }
        }
    }
}

public struct UserPreferences: Codable, Equatable, Sendable {
    public var refreshProfile: RefreshProfile
    public var liveQuotaRefreshInterval: LiveQuotaRefreshInterval
    public var providers: [Provider]
    public var accountQuotaConsents: Set<Provider>
    public var menuBarMetrics: [MenuBarMetric]
    public var quotaDisplayMode: QuotaDisplayMode
    public var notificationPreferences: QuotaNotificationPreferences
    public var petModeEnabled: Bool
    public var showProviderNamesInPetMode: Bool
    public var petSelection: [Provider: String]

    public init(
        refreshProfile: RefreshProfile = .efficient,
        liveQuotaRefreshInterval: LiveQuotaRefreshInterval = .oneMinute,
        providers: [Provider] = [.claude, .codex],
        accountQuotaConsents: Set<Provider> = [],
        menuBarMetrics: [MenuBarMetric] = [],
        quotaDisplayMode: QuotaDisplayMode = .remaining,
        notificationPreferences: QuotaNotificationPreferences = QuotaNotificationPreferences(),
        petModeEnabled: Bool = false,
        showProviderNamesInPetMode: Bool = false,
        petSelection: [Provider: String] = [:]
    ) {
        self.refreshProfile = refreshProfile
        self.liveQuotaRefreshInterval = liveQuotaRefreshInterval
        self.providers = providers
        self.accountQuotaConsents = accountQuotaConsents
        self.menuBarMetrics = menuBarMetrics
        self.quotaDisplayMode = quotaDisplayMode
        self.notificationPreferences = notificationPreferences
        self.petModeEnabled = petModeEnabled
        self.showProviderNamesInPetMode = showProviderNamesInPetMode
        self.petSelection = petSelection
    }

    /// Fresh installs use the compact companion presentation while account
    /// access remains an explicit, per-provider choice.
    public static let `default` = UserPreferences(
        petModeEnabled: true,
        petSelection: [.codex: "bsod"]
    )
    public static let iconOnly = UserPreferences(providers: [], menuBarMetrics: [])

    private enum CodingKeys: String, CodingKey {
        case refreshProfile
        case liveQuotaRefreshInterval
        case providers
        case accountQuotaConsents
        case menuBarMetrics
        case quotaDisplayMode
        case notificationPreferences
        case petModeEnabled
        case showProviderNamesInPetMode
        case petSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshProfile = try container.decodeIfPresent(RefreshProfile.self, forKey: .refreshProfile) ?? .efficient
        liveQuotaRefreshInterval = try container.decodeIfPresent(
            LiveQuotaRefreshInterval.self,
            forKey: .liveQuotaRefreshInterval
        ) ?? .oneMinute
        providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? [.claude, .codex]
        if container.contains(.accountQuotaConsents) {
            accountQuotaConsents = Set(
                try container.decodeIfPresent([Provider].self, forKey: .accountQuotaConsents) ?? []
            )
        } else {
            // Account probing is an explicit privacy choice. Legacy payloads
            // keep provider visibility but start with all account checks off;
            // cached quota and local history remain available.
            accountQuotaConsents = []
        }
        menuBarMetrics = try container.decodeIfPresent([MenuBarMetric].self, forKey: .menuBarMetrics)
            ?? []
        quotaDisplayMode = try container.decodeIfPresent(QuotaDisplayMode.self, forKey: .quotaDisplayMode) ?? .remaining
        notificationPreferences = try container.decodeIfPresent(
            QuotaNotificationPreferences.self,
            forKey: .notificationPreferences
        ) ?? QuotaNotificationPreferences()
        petModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .petModeEnabled) ?? false
        showProviderNamesInPetMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .showProviderNamesInPetMode
        ) ?? false
        petSelection = Self.decodePetSelection(from: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshProfile, forKey: .refreshProfile)
        try container.encode(liveQuotaRefreshInterval, forKey: .liveQuotaRefreshInterval)
        try container.encode(providers, forKey: .providers)
        try container.encode(
            Provider.allCases.filter(accountQuotaConsents.contains),
            forKey: .accountQuotaConsents
        )
        try container.encode(menuBarMetrics, forKey: .menuBarMetrics)
        try container.encode(quotaDisplayMode, forKey: .quotaDisplayMode)
        try container.encode(notificationPreferences, forKey: .notificationPreferences)
        try container.encode(petModeEnabled, forKey: .petModeEnabled)
        try container.encode(showProviderNamesInPetMode, forKey: .showProviderNamesInPetMode)
        try container.encode(Self.encodedPetSelection(petSelection), forKey: .petSelection)
    }

    private static func decodePetSelection(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [Provider: String] {
        guard container.contains(.petSelection) else {
            return [:]
        }

        if let object = try? container.decode([String: String].self, forKey: .petSelection) {
            return decodedPetSelection(fromObject: object)
        }

        if let legacyValues = try? container.decode([String].self, forKey: .petSelection),
           legacyValues.count.isMultiple(of: 2) {
            var selection: [Provider: String] = [:]
            for index in stride(from: 0, to: legacyValues.count, by: 2) {
                guard let provider = Provider(rawValue: legacyValues[index]) else {
                    continue
                }
                selection[provider] = legacyValues[index + 1]
            }
            return selection
        }

        return [:]
    }

    private static func decodedPetSelection(fromObject object: [String: String]) -> [Provider: String] {
        object.reduce(into: [:]) { result, entry in
            guard let provider = Provider(rawValue: entry.key) else {
                return
            }
            result[provider] = entry.value
        }
    }

    private static func encodedPetSelection(_ selection: [Provider: String]) -> [String: String] {
        selection.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}
