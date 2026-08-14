import UsageCore

protocol PricingCatalogLoading: Sendable {
    func load() async -> PricingCatalog
}

struct LivePricingCatalogLoader: PricingCatalogLoading, Sendable {
    func load() async -> PricingCatalog {
        .bundled
    }
}
