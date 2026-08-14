import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test
@MainActor
func liveAppUsesTheResilientPricingLoader() {
    let model = AppModel.live(notificationPoster: NoopPricingNotificationPoster())

    #expect(model.pricingCatalogLoader is LivePricingCatalogLoader)
}

@MainActor
private final class NoopPricingNotificationPoster: QuotaNotificationPosting {
    func authorizationState() async -> NotificationAuthorizationState { .unknown }
    func requestAuthorization() async {}
    func post(_ notifications: [QuotaNotification]) async -> Bool { true }
}

@Test
func freshCachedPricingLoadsWithoutNetworkRefresh() async throws {
    let cacheURL = temporaryCacheURL()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let dataSource = PricingDataSourceStub(result: .success(pricingDocument(model: "remote-model")))
    try LivePricingCatalogLoader.writeCacheForTesting(
        pricingDocument(model: "cached-model"),
        fetchedAt: now.addingTimeInterval(-60),
        to: cacheURL
    )

    let catalog = await LivePricingCatalogLoader(
        dataSource: dataSource,
        cacheURL: cacheURL,
        now: { now }
    ).load()

    #expect(catalog.status == .cached)
    #expect(catalog.fetchedAt == now.addingTimeInterval(-60))
    #expect(try catalog.pricing(for: "cached-model").input == 2)
    #expect(await dataSource.requestCount == 0)
}

@Test
func staleCachedPricingRefreshesAndPersistsFreshRates() async throws {
    let cacheURL = temporaryCacheURL()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let dataSource = PricingDataSourceStub(result: .success(pricingDocument(model: "fresh-model")))
    try LivePricingCatalogLoader.writeCacheForTesting(
        pricingDocument(model: "stale-model"),
        fetchedAt: now.addingTimeInterval(-(25 * 60 * 60)),
        to: cacheURL
    )

    let catalog = await LivePricingCatalogLoader(
        dataSource: dataSource,
        cacheURL: cacheURL,
        now: { now }
    ).load()

    #expect(catalog.status == .fresh)
    #expect(catalog.fetchedAt == now)
    #expect(try catalog.pricing(for: "fresh-model").output == 8)
    #expect(await dataSource.requestCount == 1)

    let offlineCatalog = await LivePricingCatalogLoader(
        dataSource: PricingDataSourceStub(result: .failure(TestPricingError.offline)),
        cacheURL: cacheURL,
        now: { now.addingTimeInterval(60) }
    ).load()
    #expect(offlineCatalog.status == .cached)
    #expect(try offlineCatalog.pricing(for: "fresh-model").input == 2)
}

@Test
func freshPricingRemainsInMemoryWhenCacheWriteFails() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let dataSource = PricingDataSourceStub(result: .success(pricingDocument(model: "fresh-model")))
    let loader = LivePricingCatalogLoader(
        dataSource: dataSource,
        cacheURL: URL(fileURLWithPath: "/dev/null/pricing-cache.json"),
        now: { now }
    )

    let first = await loader.load()
    let second = await loader.load()

    #expect(try first.pricing(for: "fresh-model").input == 2)
    #expect(try second.pricing(for: "fresh-model").input == 2)
    #expect(await dataSource.requestCount == 1)
}

@Test
func failedRefreshUsesStaleCacheInsteadOfDroppingPricing() async throws {
    let cacheURL = temporaryCacheURL()
    let now = Date(timeIntervalSince1970: 2_000_000)
    try LivePricingCatalogLoader.writeCacheForTesting(
        pricingDocument(model: "cached-model"),
        fetchedAt: now.addingTimeInterval(-(48 * 60 * 60)),
        to: cacheURL
    )

    let catalog = await LivePricingCatalogLoader(
        dataSource: PricingDataSourceStub(result: .failure(TestPricingError.offline)),
        cacheURL: cacheURL,
        now: { now }
    ).load()

    #expect(catalog.status == .cached)
    #expect(try catalog.pricing(for: "cached-model").input == 2)
}

@Test
func failedRefreshIsRateLimitedWhileUsingStaleCache() async {
    let cacheURL = temporaryCacheURL()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let dataSource = PricingDataSourceStub(result: .failure(TestPricingError.offline))
    try? LivePricingCatalogLoader.writeCacheForTesting(
        pricingDocument(model: "cached-model"),
        fetchedAt: now.addingTimeInterval(-(48 * 60 * 60)),
        to: cacheURL
    )
    let loader = LivePricingCatalogLoader(
        dataSource: dataSource,
        cacheURL: cacheURL,
        now: { now }
    )

    _ = await loader.load()
    let catalog = await loader.load()

    #expect(catalog.status == .cached)
    #expect(await dataSource.requestCount == 1)
}

@Test
func missingCacheAndFailedRefreshUsesAuditedFallback() async {
    let catalog = await LivePricingCatalogLoader(
        dataSource: PricingDataSourceStub(result: .failure(TestPricingError.offline)),
        cacheURL: temporaryCacheURL(),
        now: { Date(timeIntervalSince1970: 2_000_000) }
    ).load()

    #expect(catalog.status == .fallback)
    #expect(catalog.provenance == .bundledAudited)
}

@Test
func futureDatedCacheDoesNotSuppressNetworkRefresh() async throws {
    let cacheURL = temporaryCacheURL()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let dataSource = PricingDataSourceStub(result: .success(pricingDocument(model: "fresh-model")))
    try LivePricingCatalogLoader.writeCacheForTesting(
        pricingDocument(model: "future-model"),
        fetchedAt: now.addingTimeInterval(60 * 60),
        to: cacheURL
    )

    let catalog = await LivePricingCatalogLoader(
        dataSource: dataSource,
        cacheURL: cacheURL,
        now: { now }
    ).load()

    #expect(catalog.status == .fresh)
    #expect(try catalog.pricing(for: "fresh-model").input == 2)
    #expect(await dataSource.requestCount == 1)
}

private actor PricingDataSourceStub: PricingCatalogDataSource {
    private let result: Result<Data, Error>
    private(set) var requestCount = 0

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func pricingData() async throws -> Data {
        requestCount += 1
        return try result.get()
    }
}

private enum TestPricingError: Error { case offline }

private func temporaryCacheURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "usage-model-rates.json")
}

private func pricingDocument(model: String) -> Data {
    Data(
        """
        {
          "\(model)": {
            "input_cost_per_token": 0.000002,
            "output_cost_per_token": 0.000008,
            "cache_read_input_token_cost": 0.0000002,
            "cache_creation_input_token_cost": 0.0000025
          }
        }
        """.utf8
    )
}
