import XCTest
@testable import OpenUsage

/// Kimi-via-OpenCode attribution: BYO-key `kimi-for-coding` rows fold into the Kimi card priced
/// through the shared engine (OpenCode records them at $0); OpenCode-hosted kimi models stay out.
final class OpenCodeKimiUsageScannerTests: XCTestCase {
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "kimi-k3": ModelRates(
                inputPerMillion: 3,
                outputPerMillion: 15,
                cacheWritePerMillion: 3,
                cacheReadPerMillion: 0.3
            ),
            "kimi-k2.7-code": ModelRates(
                inputPerMillion: 0.95,
                outputPerMillion: 4,
                cacheWritePerMillion: 0.95,
                cacheReadPerMillion: 0.095
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    func testParsesZeroCostKimiRows() {
        let json = #"""
        [[1773300000000, 0, 21866, "k3", 10000, 5000, 0, 200, 50, "msg_1"],
         [1773300001000, 0.04, 500, "kimi-for-coding", 100, 0, 0, 100, 0, "msg_2"]]
        """#
        let rows = OpenCodeKimiUsageScanner.parseRows(json)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "msg_1")
        XCTAssertEqual(rows[0].model, "k3")
        XCTAssertEqual(rows[0].cost, 0)
        XCTAssertEqual(rows[0].tokens.input, 10000)
        XCTAssertEqual(rows[0].tokens.cacheRead, 5000)
        XCTAssertEqual(rows[0].tokens.output, 250)
        XCTAssertEqual(rows[1].cost, 0.04)
    }

    func testModelAliasesResolveToCatalogSlugs() {
        XCTAssertEqual(OpenCodeKimiUsageScanner.pricingModelAlias(for: "k3"), "kimi-k3")
        XCTAssertEqual(OpenCodeKimiUsageScanner.pricingModelAlias(for: "K3-256K"), "kimi-k3")
        XCTAssertEqual(OpenCodeKimiUsageScanner.pricingModelAlias(for: "kimi-for-coding"), "kimi-k2.7-code")
        XCTAssertNil(OpenCodeKimiUsageScanner.pricingModelAlias(for: "some-other-model"))
    }

    func testQuerySelectsOnlyByoKeyKimiProviders() {
        let sql = OpenCodeKimiUsageScanner.dataSQL(cutoffMs: 1_773_000_000_000)
        XCTAssertTrue(sql.contains("'kimi-for-coding'"))
        XCTAssertFalse(sql.contains("'opencode'"))
        XCTAssertTrue(sql.contains("'assistant'"))
    }

    func testDeduplicationKeepsFullestCopy() {
        let older = OpenCodeKimiUsageScanner.Row(
            id: "m1", timestamp: Date(timeIntervalSince1970: 100), model: "k3", cost: 0,
            tokens: TokenBreakdown(input: 1, cacheWrite5m: 0, cacheRead: 0, output: 1),
            reportedTotalTokens: 2
        )
        let newer = OpenCodeKimiUsageScanner.Row(
            id: "m1", timestamp: Date(timeIntervalSince1970: 200), model: "k3", cost: 0,
            tokens: TokenBreakdown(input: 5, cacheWrite5m: 0, cacheRead: 0, output: 5),
            reportedTotalTokens: 10
        )
        let out = OpenCodeKimiUsageScanner.deduplicated([older, newer])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].reportedTotalTokens, 10)
    }

    func testPricingMathThroughSharedEngine() {
        // 1M input + 1M output of k3 at $3/$15 = $18.
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 0, cacheRead: 0, output: 1_000_000)
        let cost = pricing.estimatedCostDollars(model: "kimi-k3", tokens: tokens)
        XCTAssertEqual(cost ?? 0, 18, accuracy: 0.001)
    }
}
