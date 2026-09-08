import XCTest
@testable import OpenUsage

/// Covers the Total Spend card's aggregation and metric projection: which providers contribute,
/// how slices rank per metric, Cost/MTok math, and when the combined number counts as estimated.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(_ provider: Provider, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func spendLine(
        _ label: String,
        dollars: Double? = nil,
        tokens: Double? = 1_000_000,
        estimated: Bool = false
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let dollars {
            values.append(MetricValue(number: dollars, kind: .dollars, estimated: estimated))
        }
        if let tokens {
            values.append(MetricValue(number: tokens, kind: .count, label: "tokens"))
        }
        return .values(label: label, values: values)
    }

    func testSumsDollarsAndTokensAcrossProviders() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, tokens: 100_000, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25, tokens: 500_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)

        XCTAssertEqual(Set(total.slices.map(\.provider.id)), Set(["cursor", "claude"]))
        XCTAssertEqual(total.totalUSD, 9.75, accuracy: 0.0001)
        XCTAssertEqual(total.totalTokens, 600_000, accuracy: 0.0001)

        let spend = total.projection(for: .cost)
        XCTAssertEqual(spend.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(spend.centerValue, 9.75, accuracy: 0.0001)
    }

    func testProviderWithoutPeriodLineIsExcludedNotZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 1.00)]),
            // Codex has spend for yesterday only — it must not appear in today's slices.
            "codex": snapshot(codex, lines: [spendLine("Yesterday", dollars: 3.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["claude"])
    }

    func testTokensOnlyLineContributesTokensButNotSpendOrCostPerMtok() {
        let tokensOnly = spendLine("Today", dollars: nil, tokens: 500_000)
        let snapshots = ["claude": snapshot(claude, lines: [tokensOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertFalse(total.isEmpty)
        XCTAssertEqual(total.slices.first?.tokenCount, 500_000)
        XCTAssertEqual(total.slices.first?.amountUSD, 0)

        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)

        let tokens = total.projection(for: .tokens)
        XCTAssertEqual(tokens.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(tokens.centerValue, 500_000, accuracy: 0.0001)
    }

    func testDollarsOnlyLineContributesSpendButNotCostPerMtok() {
        let dollarsOnly = spendLine("Today", dollars: 4.00, tokens: nil)
        let snapshots = ["claude": snapshot(claude, lines: [dollarsOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertEqual(total.projection(for: .cost).centerValue, 4.00, accuracy: 0.0001)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testTotalIsEstimatedWhenAnySliceIsEstimated() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.00, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 4.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertTrue(total.isEstimated)
        XCTAssertTrue(total.projection(for: .cost).isEstimated)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEstimated)
        XCTAssertFalse(total.projection(for: .tokens).isEstimated)
    }

    func testCostPerMtokRanksByRateAndBlendsTotals() {
        // Claude: $10 / 1M tokens = $10/MTok
        // Cursor: $30 / 1M tokens = $30/MTok — ranks first by rate
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 30, tokens: 1_000_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(rates.slices[0].displayAmount, 30, accuracy: 0.0001)
        XCTAssertEqual(rates.slices[1].displayAmount, 10, accuracy: 0.0001)
        // Blended center: ($40 / 2M) * 1e6 = $20/MTok
        XCTAssertEqual(rates.centerValue, 20, accuracy: 0.0001)
    }

    func testCostPerMtokExcludesIncompleteProvidersFromBlend() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: nil, tokens: 9_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 5, tokens: nil)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(rates.centerValue, 10, accuracy: 0.0001)
    }

    func testTokensProjectionRanksByTokenCount() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 50, tokens: 100_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 1, tokens: 900_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let tokens = total.projection(for: .tokens)

        XCTAssertEqual(tokens.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(tokens.centerValue, 1_000_000, accuracy: 0.0001)
    }

    func testEmptyProjectionWhenNothingQualifies() {
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: [:])
        XCTAssertTrue(total.isEmpty)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }
}

/// Series-backed windows (7/14/60/180/365 days): only providers with daily `usageHistory`
/// contribute, and the window cutoffs are calendar-exact.
final class TotalSpendSeriesAggregatorTests: XCTestCase {
    private let kimi = Provider(id: "kimi", displayName: "Kimi", icon: .providerMark("kimi"))
    private let openrouter = Provider(id: "openrouter", displayName: "OpenRouter", icon: .providerMark("openrouter"))

    private let now = OpenUsageISO8601.date(from: "2026-09-09T12:00:00.000Z")!

    private func historySnapshot(_ provider: Provider, daily: [DailyUsageEntry]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: daily))
        )
    }

    private func dayEntry(_ day: String, usd: Double, tokens: Int) -> DailyUsageEntry {
        DailyUsageEntry(date: day, totalTokens: tokens, costUSD: usd)
    }

    private var snapshots: [String: ProviderSnapshot] {
        [
            "kimi": historySnapshot(kimi, daily: [
                dayEntry("2026-09-09", usd: 10, tokens: 1000),   // today
                dayEntry("2026-09-03", usd: 20, tokens: 2000),   // 6 days ago
                dayEntry("2026-08-28", usd: 40, tokens: 4000),   // 12 days ago
                dayEntry("2026-08-11", usd: 80, tokens: 8000),   // 29 days ago
                dayEntry("2026-07-12", usd: 160, tokens: 16000), // 59 days ago
                dayEntry("2026-03-13", usd: 320, tokens: 32000), // ~180 days ago
                dayEntry("2025-09-10", usd: 640, tokens: 64000)  // ~1 year ago
            ]),
            // API-period provider with a classic spend line but no daily history.
            "openrouter": ProviderSnapshot(
                providerID: openrouter.id,
                displayName: openrouter.displayName,
                lines: [.values(label: "Today", values: [MetricValue(number: 5, kind: .dollars, estimated: false)])],
                refreshedAt: now
            )
        ]
    }

    private func usd(for period: TotalSpendPeriod) -> Double {
        TotalSpendAggregator.total(for: period, providers: [kimi, openrouter], snapshots: snapshots, now: now).totalUSD
    }

    func testTodayKeepsLineBackedProviders() {
        XCTAssertEqual(usd(for: .today), 5, accuracy: 0.0001)
    }

    func testLast7DaysIncludesTodayAndSixDaysBack() {
        XCTAssertEqual(usd(for: .last7), 30, accuracy: 0.0001)
    }

    func testLast14Days() {
        XCTAssertEqual(usd(for: .last14), 70, accuracy: 0.0001)
    }

    func testLast60Days() {
        XCTAssertEqual(usd(for: .last60), 310, accuracy: 0.0001)
    }

    func testLast6MonthsExcludesDay181() {
        // 2026-03-13 is exactly 181 days before 2026-09-09 — outside the 180-day window.
        XCTAssertEqual(usd(for: .last180), 310, accuracy: 0.0001)
    }

    func testLastYearIncludesEverything() {
        XCTAssertEqual(usd(for: .last365), 1270, accuracy: 0.0001)
    }

    func testSeriesSlicesAreMarkedEstimated() {
        let total = TotalSpendAggregator.total(for: .last14, providers: [kimi], snapshots: snapshots, now: now)
        XCTAssertTrue(total.isEstimated)
    }
}
