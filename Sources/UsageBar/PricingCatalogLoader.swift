import Foundation
import UsageCore

protocol PricingCatalogLoading: Sendable {
    func load() async -> PricingCatalog
}

struct LivePricingCatalogLoader: PricingCatalogLoading, Sendable {
    static let ratesURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!
    static let freshnessInterval: TimeInterval = 24 * 60 * 60
    static let failedRefreshRetryInterval: TimeInterval = 60 * 60

    private struct CachedRates: Codable {
        let fetchedAt: Date
        let document: Data
    }

    private let dataSource: any PricingCatalogDataSource
    private let cacheURL: URL
    private let now: @Sendable () -> Date
    private let refreshAttempts = PricingRefreshAttemptStore()

    init(
        dataSource: any PricingCatalogDataSource = URLSessionPricingCatalogDataSource(url: ratesURL),
        cacheURL: URL = AppSupportDirectory.current.appending(path: "litellm-pricing.json"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dataSource = dataSource
        self.cacheURL = cacheURL
        self.now = now
    }

    func load() async -> PricingCatalog {
        let loadedAt = now()
        if let catalog = await refreshAttempts.freshCatalog(
            at: loadedAt,
            maximumAge: Self.freshnessInterval
        ) {
            return catalog
        }
        let cached = Self.readCache(from: cacheURL)
        let cachedAge = cached.map { loadedAt.timeIntervalSince($0.fetchedAt) }
        if let cached,
           let cachedAge,
           cachedAge >= 0,
           cachedAge < Self.freshnessInterval,
           let catalog = Self.catalog(from: cached, status: .cached) {
            return catalog
        }

        guard await refreshAttempts.beginAttempt(
            at: loadedAt,
            minimumInterval: Self.failedRefreshRetryInterval
        ) else {
            if let cached, let catalog = Self.catalog(from: cached, status: .cached) {
                return catalog
            }
            return .bundled
        }

        if let remote = try? await dataSource.pricingData(),
           let catalog = try? PricingCatalog.liteLLM(
               data: remote,
               effectiveDate: Self.dateString(loadedAt),
               status: .fresh,
               source: Self.ratesURL.absoluteString,
               fetchedAt: loadedAt
           ) {
            try? Self.writeCache(remote, fetchedAt: loadedAt, to: cacheURL)
            await refreshAttempts.recordFreshCatalog(catalog, loadedAt: loadedAt)
            return catalog
        }

        if let cached, let catalog = Self.catalog(from: cached, status: .cached) {
            return catalog
        }
        return .bundled
    }

    static func writeCacheForTesting(_ document: Data, fetchedAt: Date, to url: URL) throws {
        try writeCache(document, fetchedAt: fetchedAt, to: url)
    }

    private static func catalog(from cached: CachedRates, status: PricingCatalogStatus) -> PricingCatalog? {
        try? PricingCatalog.liteLLM(
            data: cached.document,
            effectiveDate: dateString(cached.fetchedAt),
            status: status,
            source: ratesURL.absoluteString,
            fetchedAt: cached.fetchedAt
        )
    }

    private static func readCache(from url: URL) -> CachedRates? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let envelope = try? JSONDecoder().decode(CachedRates.self, from: data) {
            return envelope
        }

        // Migrate the original raw LiteLLM cache without throwing away a useful offline snapshot.
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return CachedRates(fetchedAt: modifiedAt, document: data)
    }

    private static func writeCache(_ document: Data, fetchedAt: Date, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoded = try JSONEncoder().encode(CachedRates(fetchedAt: fetchedAt, document: document))
        try encoded.write(to: url, options: .atomic)
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}

private actor PricingRefreshAttemptStore {
    private var lastAttemptAt: Date?
    private var currentCatalog: (loadedAt: Date, catalog: PricingCatalog)?

    func freshCatalog(at date: Date, maximumAge: TimeInterval) -> PricingCatalog? {
        guard let currentCatalog else { return nil }
        let age = date.timeIntervalSince(currentCatalog.loadedAt)
        guard age >= 0, age < maximumAge else { return nil }
        return currentCatalog.catalog
    }

    func recordFreshCatalog(_ catalog: PricingCatalog, loadedAt: Date) {
        currentCatalog = (loadedAt, catalog)
    }

    func beginAttempt(at date: Date, minimumInterval: TimeInterval) -> Bool {
        if let lastAttemptAt,
           date.timeIntervalSince(lastAttemptAt) >= 0,
           date.timeIntervalSince(lastAttemptAt) < minimumInterval {
            return false
        }
        lastAttemptAt = date
        return true
    }
}
