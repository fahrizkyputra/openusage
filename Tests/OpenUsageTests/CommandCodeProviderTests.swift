import XCTest
@testable import OpenUsage

// Shapes captured from the live API (GOAT plan), values trimmed.
private let whoamiJSON = #"{"success":true,"user":{"id":"u1","name":"N","email":"e@example.com","userName":"n"},"org":null}"#
private let creditsJSON = #"""
{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":20.25,"purchasedCredits":3,"freeCredits":1.5},
 "windowLimits":{"limited":true,"exceeded":null,
   "fiveHour":{"used":1.19,"cap":14,"exceeded":false,"resetAt":1790930159548},
   "weekly":{"used":3.9,"cap":35,"exceeded":false,"resetAt":1791114669043}},
 "sandboxAccess":false,"sandboxMinutes":null}
"""#
private let subscriptionJSON = #"{"success":true,"data":{"id":"s1","status":"active","planId":"individual-goat","currentPeriodStart":"2026-09-09T04:59:00.000Z","currentPeriodEnd":"2026-10-09T04:59:00.000Z"}}"#
private func summaryJSON(count: Int, cost: Double, tokens: Int) -> String {
    #"{"totalCount":\#(count),"totalCost":\#(cost),"totalTokens":\#(tokens),"periodBasis":"billing-period"}"#
}

/// Pinned to a local noon inside the billing period, so Today and Yesterday are both covered.
private let fixedNow = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!

private func response(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
}

final class CommandCodeMapperTests: XCTestCase {
    func testCreditLinesReadTheWindowsMonthlyAndExtra() throws {
        let subscription = try XCTUnwrap(CommandCodeUsageMapper.subscription(Data(subscriptionJSON.utf8)))
        XCTAssertEqual(subscription.plan?.name, "GOAT")
        let lines = try XCTUnwrap(CommandCodeUsageMapper.creditLines(Data(creditsJSON.utf8), subscription: subscription))

        guard case .progress(let label, let used, let cap, let format, let reset, let period, _) = lines[0] else {
            return XCTFail("5-hour meter")
        }
        XCTAssertEqual(label, "5-hour")
        XCTAssertEqual(used, 1.19)
        XCTAssertEqual(cap, 14)
        XCTAssertEqual(format, .dollars)
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_790_930_159.548), "resetAt is epoch milliseconds")
        XCTAssertEqual(period, CommandCodeUsageMapper.fiveHourPeriodMs)

        guard case .progress("Weekly", 3.9, 35, _, _, _, _) = lines[1] else { return XCTFail("weekly meter") }
        guard case .progress("Monthly", let monthlyUsed, 70, _, let monthlyReset, _, _) = lines[2] else {
            return XCTFail("monthly meter against the GOAT allocation")
        }
        XCTAssertEqual(monthlyUsed, 70 - 20.25, accuracy: 0.0001)
        XCTAssertEqual(monthlyReset, subscription.periodEnd)
        guard case .values("Extra credits", let extra, _, _, _, _) = lines[3] else { return XCTFail("extra credits") }
        XCTAssertEqual(extra.first?.number, 4.5)
    }

    func testUnknownPlanRebuildsMonthlyFromWhatsLeftAndNoSubscriptionSkipsIt() throws {
        var unknown = try XCTUnwrap(CommandCodeUsageMapper.subscription(Data(subscriptionJSON.utf8)))
        unknown.planID = "enterprise-custom"
        let lines = try XCTUnwrap(CommandCodeUsageMapper.creditLines(Data(creditsJSON.utf8), subscription: unknown))
        guard case .progress("Monthly", 0, 20.25, _, _, _, _) = lines[2] else {
            return XCTFail("unknown plan: limit is what's left, nothing counted as used")
        }

        let payAsYouGo = try XCTUnwrap(CommandCodeUsageMapper.creditLines(Data(creditsJSON.utf8), subscription: nil))
        XCTAssertFalse(payAsYouGo.contains { $0.label == "Monthly" })
        XCTAssertNil(CommandCodeUsageMapper.subscription(Data(#"{"success":true,"data":{"status":"canceled","planId":"individual-go"}}"#.utf8)))
    }

    func testUnlimitedWindowsAreSkipped() throws {
        let body = #"{"credits":{"monthlyCredits":5},"windowLimits":{"limited":false,"fiveHour":{"used":1,"cap":2}}}"#
        let lines = try XCTUnwrap(CommandCodeUsageMapper.creditLines(Data(body.utf8), subscription: nil))
        XCTAssertEqual(lines.map(\.label), ["Extra credits"])
    }

    func testPlanLookupPrefersTheLongestPrefix() {
        XCTAssertEqual(CommandCodeUsageMapper.plan(for: "individual-pro-v1")?.monthlyCredits, 80)
        XCTAssertEqual(CommandCodeUsageMapper.plan(for: "individual-pro")?.monthlyCredits, 30)
        XCTAssertEqual(CommandCodeUsageMapper.plan(for: "INDIVIDUAL_GOAT")?.name, "GOAT")
        XCTAssertNil(CommandCodeUsageMapper.plan(for: "something-else"))
    }

    func testYesterdayIsTheDifferenceAndDaysBeforeThePeriodAreLeftOut() {
        let today = CommandCodeUsageMapper.Summary(requests: 400, costUSD: 2.0, tokens: 1000)
        let both = CommandCodeUsageMapper.Summary(requests: 420, costUSD: 2.5, tokens: 1600)
        let start = Calendar.current.startOfDay(for: fixedNow)

        let lines = CommandCodeUsageMapper.spendLines(sinceToday: today, sinceYesterday: both,
                                                      periodStart: start.addingTimeInterval(-10 * 86_400), now: fixedNow)
        guard case .values("Today", let t, _, _, _, _) = lines[0],
              case .values("Yesterday", let y, _, _, _, _) = lines[1] else { return XCTFail("today + yesterday") }
        XCTAssertEqual(t.first { $0.kind == .dollars }?.number, 2.0)
        XCTAssertEqual(t.first { $0.kind == .dollars }?.estimated, false, "billed, not estimated")
        XCTAssertEqual(y.first { $0.kind == .dollars }?.number ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(y.first { $0.label == "tokens" }?.number, 600)

        let periodStartedThisMorning = CommandCodeUsageMapper.spendLines(
            sinceToday: today, sinceYesterday: both, periodStart: start.addingTimeInterval(3600), now: fixedNow)
        XCTAssertTrue(periodStartedThisMorning.isEmpty, "the API can't see the part of a day before the period")
        let periodStartedToday = CommandCodeUsageMapper.spendLines(
            sinceToday: today, sinceYesterday: both, periodStart: start, now: fixedNow)
        XCTAssertEqual(periodStartedToday.map(\.label), ["Today"])
    }
}

@MainActor
final class CommandCodeProviderTests: XCTestCase {
    private func makeProvider(
        files: [String: String] = [CommandCodeAuthStore.configPaths[0]: #"{"apiKey":"user_key"}"#],
        environment: [String: String] = [:],
        handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) -> (CommandCodeProvider, RoutingHTTPClient) {
        let http = RoutingHTTPClient { handler($0) }
        let provider = CommandCodeProvider(
            authStore: CommandCodeAuthStore(files: FakeFiles(files), environment: FakeEnvironment(environment)),
            usageClient: CommandCodeUsageClient(http: http, environment: FakeEnvironment(environment)),
            now: { fixedNow }
        )
        return (provider, http)
    }

    nonisolated private static func liveHandler(_ request: HTTPRequest) -> HTTPResponse {
        XCTAssertEqual(request.url.host, "api.commandcode.ai")
        XCTAssertEqual(request.headers["Authorization"], "Bearer user_key")
        XCTAssertEqual(request.method, "GET")
        let since = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "since" }?.value.flatMap(OpenUsageISO8601.date(from:))
        let startOfToday = Calendar.current.startOfDay(for: fixedNow)
        switch request.url.path {
        case "/alpha/whoami": return response(whoamiJSON)
        case "/alpha/billing/credits": return response(creditsJSON)
        case "/alpha/billing/subscriptions": return response(subscriptionJSON)
        case "/alpha/usage/summary":
            if since == startOfToday { return response(summaryJSON(count: 400, cost: 2.0, tokens: 1000)) }
            if let since, since < startOfToday, since > startOfToday.addingTimeInterval(-2 * 86_400) {
                return response(summaryJSON(count: 420, cost: 2.5, tokens: 1600))
            }
            return response(summaryJSON(count: 5484, cost: 49.77, tokens: 9000))
        default: return response(#"{"error":"not_found"}"#, status: 404)
        }
    }

    func testRefreshBuildsTheCard() async throws {
        let (provider, http) = makeProvider(handler: Self.liveHandler)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "GOAT")
        XCTAssertEqual(snapshot.lines.map(\.label),
                       ["5-hour", "Weekly", "Monthly", "Extra credits", "Requests", "Today", "Yesterday"])
        guard case .values(_, let requests, _, _, _, _) = snapshot.line(label: "Requests") else {
            return XCTFail("requests")
        }
        XCTAssertEqual(requests.first?.number, 5484)
        XCTAssertNil(snapshot.line(label: "Last 30 Days"), "the API can't reach before the billing period")
        XCTAssertEqual(http.requests.count, 6)
        let periodSince = http.requests.first { $0.url.path == "/alpha/usage/summary"
            && $0.url.query?.contains("2026-09-09") == true }
        XCTAssertNotNil(periodSince, "requests are counted from the billing period start")
    }

    func testRejectedKeyStopsAfterWhoami() async {
        let (provider, http) = makeProvider { _ in response(#"{"error":"unauthorized"}"#, status: 401) }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testMissingKeySkipsNetwork() async {
        let (provider, http) = makeProvider(files: [:]) { _ in response("{}") }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
        let hasKey = await provider.hasLocalCredentials()
        XCTAssertFalse(hasKey)
    }

    func testOrganizationSeatScopesBillingCalls() async {
        let (provider, http) = makeProvider { request in
            if request.url.path == "/alpha/whoami" {
                return response(#"{"success":true,"user":{"id":"u1"},"org":{"id":"org_9"}}"#)
            }
            return Self.liveHandler(request)
        }

        _ = await provider.refresh()

        let scoped = http.requests.filter { $0.url.path != "/alpha/whoami" }
        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.allSatisfy { $0.url.query?.contains("orgId=org_9") == true })
    }

    func testKeySourcesInOrder() {
        let cli = [CommandCodeAuthStore.cliAuthPath: #"{"apiKey":"user_cli","userName":"n"}"#]
        let fromCLI = CommandCodeAuthStore(files: FakeFiles(cli), environment: FakeEnvironment([:]))
        XCTAssertEqual(fromCLI.loadAPIKey(), "user_cli")
        XCTAssertEqual(fromCLI.keyStatus(), .fromEnvironment)

        let env = CommandCodeAuthStore(files: FakeFiles(cli), environment: FakeEnvironment(["COMMAND_CODE_API_KEY": "user_env"]))
        XCTAssertEqual(env.loadAPIKey(), "user_env", "the environment wins over the CLI login")

        var both = cli
        both[CommandCodeAuthStore.configPaths[0]] = #"{"apiKey":"user_app"}"#
        let app = CommandCodeAuthStore(files: FakeFiles(both), environment: FakeEnvironment(["COMMAND_CODE_API_KEY": "user_env"]))
        XCTAssertEqual(app.loadAPIKey(), "user_app", "a key saved in the app wins")
        XCTAssertEqual(app.keyStatus(), .overrideActive)
    }

    func testDeletingTheAppKeyLeavesTheCLILoginAlone() throws {
        let files = FakeFiles([
            CommandCodeAuthStore.cliAuthPath: #"{"apiKey":"user_cli"}"#,
            CommandCodeAuthStore.configPaths[0]: #"{"apiKey":"user_app"}"#
        ])
        let store = CommandCodeAuthStore(files: files, environment: FakeEnvironment([:]))

        try store.deleteAPIKey()

        XCTAssertNotNil(files.files[CommandCodeAuthStore.cliAuthPath])
        XCTAssertEqual(store.loadAPIKey(), "user_cli")
    }

    func testCardIsSpendCapableWithoutLast30Days() {
        let descriptors = CommandCodeProvider().widgetDescriptors
        XCTAssertEqual(descriptors.filter(\.isSpendTile).map(\.metricLabel), ["Today", "Yesterday"])
        XCTAssertNil(descriptors.compactMap(\.historyResource).first, "no per-day history to export")
    }
}
