import XCTest
@testable import OpenUsage

// Shapes captured from the live API (GOAT plan), values trimmed.
private let ccCreditsJSON = #"""
{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":20.25,"purchasedCredits":3,"freeCredits":1.5},
 "windowLimits":{"limited":true,"exceeded":null,
   "fiveHour":{"used":1.19,"cap":14,"exceeded":false,"resetAt":1790930159548},
   "weekly":{"used":3.9,"cap":35,"exceeded":false,"resetAt":1791114669043}},
 "sandboxAccess":false,"sandboxMinutes":null}
"""#
private let ccSubscriptionJSON = #"{"success":true,"data":{"id":"s1","status":"active","planId":"individual-goat","currentPeriodStart":"2026-09-09T04:59:00.000Z","currentPeriodEnd":"2026-10-09T04:59:00.000Z"}}"#
private let ccSummaryJSON = #"{"totalCount":5484,"totalCost":49.77,"totalTokens":1561483358,"periodBasis":"billing-period"}"#

final class CommandCodeUsageMapperTests: XCTestCase {
    private func subscription() throws -> CommandCodeUsageMapper.Subscription {
        try XCTUnwrap(CommandCodeUsageMapper.subscription(Data(ccSubscriptionJSON.utf8)))
    }

    func testMapsTheWindowsMonthlyAndExtraCreditsInDeclarationOrder() throws {
        let usage = try CommandCodeUsageMapper.map(
            credits: Data(ccCreditsJSON.utf8), subscription: try subscription(), requests: 5484)

        XCTAssertEqual(usage.plan, "GOAT")
        XCTAssertEqual(usage.lines.map(\.label), ["5-hour", "Weekly", "Monthly", "Extra credits", "Requests"])
        guard case .progress("5-hour", let used, let cap, .dollars, let reset, let period) = usage.lines[0] else {
            return XCTFail("5-hour meter")
        }
        XCTAssertEqual(used, 1.19)
        XCTAssertEqual(cap, 14)
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_790_930_159.548), "resetAt is epoch milliseconds")
        XCTAssertEqual(period, CommandCodeUsageMapper.fiveHourPeriodMs)
        guard case .progress("Weekly", 3.9, 35, .dollars, _, let weeklyPeriod) = usage.lines[1] else { return XCTFail("weekly") }
        XCTAssertEqual(weeklyPeriod, CommandCodeUsageMapper.weeklyPeriodMs)
        guard case .progress("Monthly", let monthlyUsed, 70, .dollars, let monthlyReset, _) = usage.lines[2] else {
            return XCTFail("monthly against the GOAT allocation of 70")
        }
        XCTAssertEqual(monthlyUsed, 70 - 20.25, accuracy: 0.0001)
        XCTAssertEqual(monthlyReset, try subscription().periodEnd)
        guard case .values("Extra credits", let extra, _) = usage.lines[3] else { return XCTFail("extra credits") }
        XCTAssertEqual(extra.first?.number, 4.5, "purchased plus free")
        guard case .values("Requests", let requests, _) = usage.lines[4] else { return XCTFail("requests") }
        XCTAssertEqual(requests.first?.number, 5484)
    }

    func testAnUnknownPlanRebuildsMonthlyFromWhatIsLeft() throws {
        var unknown = try subscription()
        unknown.planID = "enterprise-custom"
        let usage = try CommandCodeUsageMapper.map(credits: Data(ccCreditsJSON.utf8), subscription: unknown, requests: nil)
        guard case .progress("Monthly", 0, 20.25, _, _, _) = usage.lines[2] else {
            return XCTFail("unknown plan: the limit is what is left and nothing counts as used")
        }
        XCTAssertNil(usage.plan)
    }

    func testNoSubscriptionSkipsMonthlyAndAnInactiveOneIsIgnored() throws {
        let payAsYouGo = try CommandCodeUsageMapper.map(credits: Data(ccCreditsJSON.utf8), subscription: nil, requests: nil)
        XCTAssertFalse(payAsYouGo.lines.contains { $0.label == "Monthly" })
        XCTAssertNil(CommandCodeUsageMapper.subscription(
            Data(#"{"success":true,"data":{"status":"canceled","planId":"individual-go"}}"#.utf8)))
    }

    func testUnlimitedWindowsAreDroppedButExtraCreditsStay() throws {
        let body = #"{"credits":{"monthlyCredits":5},"windowLimits":{"limited":false,"fiveHour":{"used":1,"cap":2}}}"#
        let usage = try CommandCodeUsageMapper.map(credits: Data(body.utf8), subscription: nil, requests: nil)
        XCTAssertEqual(usage.lines.map(\.label), ["Extra credits"])
    }

    func testAPayloadWithoutCreditsIsInvalid() {
        XCTAssertThrowsError(try CommandCodeUsageMapper.map(credits: Data("{}".utf8), subscription: nil, requests: nil)) {
            XCTAssertEqual($0 as? ProviderError, .invalidResponse)
        }
        XCTAssertThrowsError(try CommandCodeUsageMapper.map(credits: Data("not json".utf8), subscription: nil, requests: nil))
    }

    func testPlanLookupPrefersTheLongestPrefix() {
        XCTAssertEqual(CommandCodeUsageMapper.plan(for: "individual-pro-v1")?.monthlyCredits, 80)
        XCTAssertEqual(CommandCodeUsageMapper.plan(for: "individual-pro")?.monthlyCredits, 30)
        XCTAssertEqual(CommandCodeUsageMapper.plan(for: "INDIVIDUAL_GOAT")?.name, "GOAT")
        XCTAssertNil(CommandCodeUsageMapper.plan(for: "something-else"))
    }

    func testOrganizationAndSummaryAreParsedFromTheirBodies() {
        XCTAssertNil(CommandCodeUsageMapper.organizationID(Data(#"{"success":true,"user":{"id":"u"},"org":null}"#.utf8)))
        XCTAssertEqual(CommandCodeUsageMapper.organizationID(Data(#"{"org":{"id":" org_9 "}}"#.utf8)), "org_9")
        let summary = CommandCodeUsageMapper.summary(Data(ccSummaryJSON.utf8))
        XCTAssertEqual(summary, .init(requests: 5484, costUSD: 49.77, tokens: 1_561_483_358))
        XCTAssertNil(CommandCodeUsageMapper.summary(Data("{}".utf8)))
    }
}
