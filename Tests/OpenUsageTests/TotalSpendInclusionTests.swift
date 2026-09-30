import XCTest
@testable import OpenUsage

@MainActor
final class TotalSpendInclusionTests: XCTestCase {
    private func makeStore(_ defaults: UserDefaults) -> LayoutStore {
        let claude = ClaudeProvider()
        let nineRouter = NineRouterProvider()
        let registry = WidgetRegistry.from([claude, nineRouter])
        return LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TotalSpendInclusionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEverySpendProviderCountsByDefaultIncluding9router() {
        let store = makeStore(makeDefaults())
        XCTAssertEqual(Set(store.spendCapableProviders.map(\.id)), ["claude", "9router"])
        XCTAssertTrue(store.isSpendCapable("9router"))
        XCTAssertTrue(store.isIncludedInTotalSpend("claude"))
    }

    func testExcludingAProviderDropsItFromTheTotalAndPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)

        store.setIncludedInTotalSpend(false, for: "claude")

        XCTAssertEqual(store.spendCapableProviders.map(\.id), ["9router"])
        XCTAssertFalse(makeStore(defaults).isIncludedInTotalSpend("claude"), "exclusion survives relaunch")
        XCTAssertTrue(makeStore(defaults).isIncludedInTotalSpend("9router"))
    }

    func testResetRestoresInclusion() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        store.setIncludedInTotalSpend(false, for: "claude")
        store.setIncludedInTotalSpend(false, for: "9router")

        store.resetProvider("claude")
        XCTAssertTrue(store.isIncludedInTotalSpend("claude"))
        XCTAssertFalse(store.isIncludedInTotalSpend("9router"), "per-provider reset only touches that provider")

        store.resetToDefault()
        XCTAssertTrue(store.isIncludedInTotalSpend("9router"))
    }

    func testTotalSpendSums9routerTiles() {
        let provider = NineRouterProvider().provider
        let lines: [MetricLine] = [
            .values(label: "Today", values: [
                MetricValue(number: 12.5, kind: .dollars, estimated: true),
                MetricValue(number: 1000, kind: .count, label: "tokens")
            ])
        ]
        let snapshot = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: lines)

        let total = TotalSpendAggregator.total(for: .today, providers: [provider], snapshots: [provider.id: snapshot])

        XCTAssertEqual(total.totalUSD, 12.5)
        XCTAssertEqual(total.totalTokens, 1000)
        XCTAssertTrue(total.isEstimated)
    }
}
