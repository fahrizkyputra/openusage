import XCTest
@testable import OpenUsage

private let machineID = "4f0c2b8e-machine"
private let cliSecret = "a1b2c3d4e5f6"

private let statsJSON = #"""
{"totalRequests":1613,"totalPromptTokens":1200000,"totalCompletionTokens":34000,"totalCachedTokens":596322,
 "totalCost":34.88,"byProvider":{"claude":{"requests":1613}},
 "byModel":{"opus|claude":{"rawModel":"claude-opus-5-5","provider":"claude","promptTokens":1000000,"completionTokens":34000,"cost":30.0},
            "glm|glm":{"rawModel":"glm-5.3","provider":"glm","promptTokens":200000,"completionTokens":0,"cost":4.88}},
 "pending":{},"recentRequests":[]}
"""#

/// 30 days, oldest first; day i costs i dollars and 1000*i tokens, so today = $29, yesterday = $28.
private let chartJSON: String = {
    let points = (0..<30).map { #"{"label":"x","tokens":\#($0 * 1000),"cost":\#($0),"requests":\#($0)}"# }
    return "[" + points.joined(separator: ",") + "]"
}()

/// Noon on a fixed local date, so Today / Yesterday are unambiguous in any test-runner zone.
private let fixedNow: Date = {
    Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
}()

private func spend(_ line: MetricLine?) -> (cost: Double?, tokens: Double?, estimated: Bool)? {
    guard case .values(_, let values, _, _, _, _) = line else { return nil }
    let dollars = values.first { $0.kind == .dollars }
    return (dollars?.number, values.first { $0.kind == .count }?.number, dollars?.estimated ?? false)
}

private let connectionsJSON = #"""
{"connections":[
  {"id":"claude-1","provider":"claude","authType":"oauth","name":"Account 1","isActive":true},
  {"id":"claude-2","provider":"claude","authType":"oauth","name":"Account 2","isActive":true},
  {"id":"glm-1","provider":"glm","authType":"apikey","name":"GLM","isActive":true},
  {"id":"off-1","provider":"commandcode","authType":"apikey","name":"off","isActive":false}
]}
"""#

private let claudeAccount1JSON = #"""
{"plan":"Claude Code","quotas":{
  "session (5h)":{"used":96,"total":100,"remaining":4,"resetAt":"2026-09-28T16:30:00.306Z","unlimited":false},
  "weekly (7d)":{"used":55,"total":100,"remaining":45,"resetAt":"2026-10-03T02:00:00.306Z","unlimited":false},
  "weekly fable (7d)":{"used":99,"total":100,"remaining":1,"resetAt":"2026-10-03T02:00:00.000Z","unlimited":false}
}}
"""#

private let claudeAccount2JSON = #"""
{"plan":"Claude Code","quotas":{
  "session (5h)":{"used":10,"total":100,"resetAt":"2026-09-28T18:00:00.000Z","unlimited":false},
  "weekly (7d)":{"used":80,"total":100,"resetAt":"2026-10-01T00:00:00.000Z","unlimited":false}
}}
"""#

private let creditBalanceJSON = #"""
{"plan":"DeepSeek","quotas":{"Balance (USD)":{"used":0,"total":0,"isCreditBalance":true,"currency":"USD"}}}
"""#

private func data(_ json: String) -> Data { Data(json.utf8) }

private func response(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: data(json))
}

private func authFiles(_ directory: String = NineRouterAuthStore.defaultDataDirectory) -> FakeFiles {
    FakeFiles([
        "\(directory)/machine-id": machineID + "\n",
        "\(directory)/auth/cli-secret": cliSecret
    ])
}

// MARK: - Auth store

final class NineRouterAuthStoreTests: XCTestCase {
    func testDerivesTheSameCLITokenAs9router() {
        // sha256("4f0c2b8e-machine" + "9r-cli-auth" + "a1b2c3d4e5f6").hex.prefix(16), as 9router's CLI computes it.
        XCTAssertEqual(NineRouterAuthStore.cliToken(machineID: machineID, secret: cliSecret), "0aa7dcf6d8e0d68f")
    }

    func testLoadsTrimmedFilesAndDefaultBaseURL() throws {
        let store = NineRouterAuthStore(files: authFiles(), environment: FakeEnvironment())

        let auth = try store.load()

        XCTAssertEqual(auth.cliToken, NineRouterAuthStore.cliToken(machineID: machineID, secret: cliSecret))
        XCTAssertEqual(auth.baseURL.absoluteString, "http://127.0.0.1:20128")
        XCTAssertTrue(store.hasCredentialFiles())
    }

    func testHonorsDataDirectoryAndBaseURLOverrides() throws {
        let store = NineRouterAuthStore(
            files: authFiles("/opt/9r"),
            environment: FakeEnvironment([
                "NINEROUTER_DATA_DIR": "/opt/9r/",
                "NINEROUTER_URL": "http://localhost:3000/"
            ])
        )

        let auth = try store.load()

        XCTAssertEqual(auth.baseURL.absoluteString, "http://localhost:3000")
        XCTAssertTrue(store.hasCredentialFiles())
    }

    func testMissingFilesReportNotInstalled() {
        let store = NineRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())

        XCTAssertFalse(store.hasCredentialFiles())
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? NineRouterAuthError, .notInstalled)
        }
    }

    func testRejectsNonHTTPBaseURL() {
        let store = NineRouterAuthStore(files: authFiles(), environment: FakeEnvironment(["NINEROUTER_URL": "ftp://x"]))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? NineRouterAuthError, .invalidBaseURL)
        }
    }
}

// MARK: - Mapper

final class NineRouterUsageMapperTests: XCTestCase {
    func testLocalChartKeysDaysByPositionAndRanksModels() throws {
        let daily = try XCTUnwrap(NineRouterDailyUsage.fromLocalChart(
            data(chartJSON), todayStats: data(statsJSON), last30Stats: data(statsJSON), now: fixedNow
        ))
        XCTAssertEqual(daily.days.count, 30)
        XCTAssertEqual(daily.days.first?.date, "2026-09-01")
        XCTAssertEqual(daily.days.last, .init(date: "2026-09-30", costUSD: 29, tokens: 29_000))
        XCTAssertEqual(daily.todayModels.map(\.model), ["claude-opus-5-5", "glm-5.3"])
        XCTAssertEqual(daily.todayModels.first?.tokens, 1_034_000)
        XCTAssertNil(NineRouterDailyUsage.fromLocalChart(data("[]"), todayStats: nil, last30Stats: nil, now: fixedNow))
    }

    func testSpendTilesYesterdayTrendAndModelBreakdowns() throws {
        let daily = try XCTUnwrap(NineRouterDailyUsage.fromLocalChart(
            data(chartJSON), todayStats: data(statsJSON), last30Stats: data(statsJSON), now: fixedNow
        ))
        var lines: [MetricLine] = []
        daily.appendLines(to: &lines, now: fixedNow, note: daily.sourceNote())

        XCTAssertEqual(lines.map(\.label), ["Today", "Yesterday", "Last 30 Days", "Usage Trend"])
        let today = try XCTUnwrap(spend(lines.first { $0.label == "Today" }))
        XCTAssertEqual(today.cost, 29)
        XCTAssertEqual(today.tokens, 29_000)
        XCTAssertTrue(today.estimated, "9router cost is API-rate pricing, not a bill")
        XCTAssertEqual(spend(lines.first { $0.label == "Yesterday" })?.cost, 28)
        XCTAssertEqual(spend(lines.first { $0.label == "Last 30 Days" })?.cost, Double((0..<30).reduce(0, +)))

        func breakdown(_ label: String) -> ModelUsageBreakdown? {
            guard case .values(_, _, _, _, _, let b) = lines.first(where: { $0.label == label }) else { return nil }
            return b
        }
        XCTAssertEqual(breakdown("Today")?.models.map(\.model), ["claude-opus-5-5", "glm-5.3"])
        XCTAssertEqual(breakdown("Last 30 Days")?.models.map(\.model), ["claude-opus-5-5", "glm-5.3"])
        XCTAssertNil(breakdown("Yesterday"), "9router only ranks models per period, so Yesterday has totals only")
    }

    func testProxyDailyParsesAndRejectsBadDates() throws {
        let body = #"{"timeZone":"UTC","days":[{"date":"2026-09-29","costUSD":1.5,"tokens":10},{"date":"2026-09-30","costUSD":2,"tokens":20}],"models":{"today":[{"model":"m","costUSD":2,"tokens":20}]}}"#
        let daily = try XCTUnwrap(NineRouterDailyUsage.parseProxy(data(body)))
        XCTAssertEqual(daily.timeZone, "UTC")
        XCTAssertEqual(daily.days.map(\.date), ["2026-09-29", "2026-09-30"])
        XCTAssertEqual(daily.todayModels.map(\.model), ["m"])
        XCTAssertNil(NineRouterDailyUsage.parseProxy(data(#"{"days":[{"date":"Sep 29","costUSD":1}]}"#)))
    }

    func testServerDaysWinOverTheMacCalendar() throws {
        // The server is already on Oct 1 while this Mac is still on Sep 30: Today must be the server's
        // last day, not an empty Mac-side "Sep 30 minus nothing".
        let body = #"{"timeZone":"Pacific/Kiritimati","days":[{"date":"2026-09-30","costUSD":1,"tokens":1},{"date":"2026-10-01","costUSD":5,"tokens":5}]}"#
        let daily = try XCTUnwrap(NineRouterDailyUsage.parseProxy(data(body)))
        var lines: [MetricLine] = []
        daily.appendLines(to: &lines, now: fixedNow, note: "n")
        XCTAssertEqual(spend(lines.first { $0.label == "Today" })?.cost, 5)
        XCTAssertEqual(spend(lines.first { $0.label == "Yesterday" })?.cost, 1)
    }

    func testSourceNoteNamesServerZoneOnlyWhenItDiffers() {
        var daily = NineRouterDailyUsage(timeZone: "UTC", days: [], todayModels: [], last30Models: [])
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        XCTAssertTrue(daily.sourceNote(macTimeZone: jakarta).contains("(UTC)"))
        daily.timeZone = "Asia/Jakarta"
        XCTAssertEqual(daily.sourceNote(macTimeZone: jakarta), NineRouterDailyUsage.estimateNote)
    }

    func testActiveConnectionsSkipsInactiveAndKeepsNames() {
        let connections = NineRouterUsageMapper.activeConnections(data(connectionsJSON))
        XCTAssertEqual(connections?.map(\.id), ["claude-1", "claude-2", "glm-1"])
        XCTAssertEqual(connections?.map(\.name), ["Account 1", "Account 2", "GLM"])
        XCTAssertNil(NineRouterUsageMapper.activeConnections(data("[]")))
    }

    func testDuplicateOrMissingConnectionNamesStayUnambiguous() {
        let body = #"""
        {"connections":[
          {"id":"a","provider":"claude","name":"Account 1","isActive":true},
          {"id":"b","provider":"codex","name":"Account 1","isActive":true},
          {"id":"c","provider":"glm","name":"  ","isActive":true}
        ]}
        """#
        XCTAssertEqual(NineRouterUsageMapper.activeConnections(data(body))?.map(\.name),
                       ["Account 1 (claude)", "Account 1 (codex)", "glm"])
    }

    func testQuotaNamesMapToAccountWideWindowsOnly() {
        XCTAssertEqual(NineRouterUsageMapper.window(forQuotaName: "session (5h)"), .session)
        XCTAssertEqual(NineRouterUsageMapper.window(forQuotaName: "Session (5h)"), .session)
        XCTAssertEqual(NineRouterUsageMapper.window(forQuotaName: "Weekly"), .weekly)
        XCTAssertEqual(NineRouterUsageMapper.window(forQuotaName: "weekly (7d)"), .weekly)
        XCTAssertNil(NineRouterUsageMapper.window(forQuotaName: "weekly fable (7d)"))
        XCTAssertNil(NineRouterUsageMapper.window(forQuotaName: "Credits"))
    }

    func testQuotasSkipCreditBalances() {
        XCTAssertTrue(NineRouterUsageMapper.quotas(data(creditBalanceJSON)).isEmpty)
        XCTAssertTrue(NineRouterUsageMapper.quotas(data(#"{"message":"Usage not available for this connection"}"#)).isEmpty)
    }

    func testTightestWindowWinsAcrossConnections() throws {
        let quotas = NineRouterUsageMapper.quotas(data(claudeAccount1JSON), source: "Account 1")
            + NineRouterUsageMapper.quotas(data(claudeAccount2JSON), source: "Account 2")

        let (lines, sources) = NineRouterUsageMapper.tightestQuotas(quotas)

        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly"])
        guard case .progress(_, let sessionUsed, 100, .percent, let sessionReset, let sessionPeriod, _) = lines[0],
              case .progress(_, let weeklyUsed, 100, .percent, let weeklyReset, _, _) = lines[1] else {
            return XCTFail("expected percent meters")
        }
        XCTAssertEqual(sessionUsed, 96)
        XCTAssertEqual(sessionReset, OpenUsageISO8601.date(from: "2026-09-28T16:30:00.306Z"))
        XCTAssertEqual(sessionPeriod, NineRouterUsageMapper.sessionPeriodMs)
        // Account 2's weekly (80%) beats Account 1's (55%); the model-specific 99% window is ignored.
        XCTAssertEqual(weeklyUsed, 80)
        XCTAssertEqual(weeklyReset, OpenUsageISO8601.date(from: "2026-10-01T00:00:00.000Z"))
        // Each meter names the account it came from — here they differ.
        XCTAssertEqual(sources, ["Session": "Account 1", "Weekly": "Account 2"])
    }

    func testNoQuotasMeansNoMeters() {
        let result = NineRouterUsageMapper.tightestQuotas([])
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertTrue(result.sources.isEmpty)
    }
}

// MARK: - Provider

@MainActor
final class NineRouterProviderTests: XCTestCase {
    private func makeProvider(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) -> (NineRouterProvider, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let provider = NineRouterProvider(
            authStore: NineRouterAuthStore(files: authFiles(), environment: FakeEnvironment()),
            usageClient: NineRouterUsageClient(http: http),
            now: { fixedNow }
        )
        return (provider, http)
    }

    func testRefreshMapsSpendAndTightestQuotas() async throws {
        let (provider, http) = makeProvider { request in
            switch request.url.path {
            case NineRouterUsageClient.statsPath: return response(statsJSON)
            case NineRouterUsageClient.chartPath: return response(chartJSON)
            case NineRouterUsageClient.providersPath: return response(connectionsJSON)
            case "/api/usage/claude-1": return response(claudeAccount1JSON)
            case "/api/usage/claude-2": return response(claudeAccount2JSON)
            case "/api/usage/glm-1": return response(#"{"plan":"Unknown","quotas":{}}"#)
            default: return response("{}", status: 404)
            }
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Accounts", "Today", "Yesterday", "Last 30 Days", "Usage Trend"])
        XCTAssertEqual(snapshot.lineSources, ["Session": "Account 1", "Weekly": "Account 2"])
        XCTAssertEqual(snapshot.accounts?.map(\.name), ["Account 1", "Account 2", "GLM"], "tightest window first, quota-less last")
        XCTAssertEqual(snapshot.usageHistory?.series.daily.count, 30)
        let token = NineRouterAuthStore.cliToken(machineID: machineID, secret: cliSecret)
        XCTAssertTrue(http.requests.allSatisfy { $0.headers[NineRouterUsageClient.tokenHeader] == token })
        let periods = http.requests.filter { $0.url.path == NineRouterUsageClient.statsPath }
            .compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
        XCTAssertEqual(periods, ["today", "30d"])
        XCTAssertTrue(http.requests.contains {
            $0.url.path == NineRouterUsageClient.chartPath && $0.url.query == "period=30d"
        })
        XCTAssertFalse(http.requests.contains { $0.url.path == "/api/usage/off-1" })
    }

    func testQuotaFailuresKeepSpendRows() async {
        let (provider, _) = makeProvider { request in
            if request.url.path == NineRouterUsageClient.statsPath { return response(statsJSON) }
            if request.url.path == NineRouterUsageClient.chartPath { return response(chartJSON) }
            return response("{}", status: 500)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Today", "Yesterday", "Last 30 Days", "Usage Trend"])
        XCTAssertNil(snapshot.lineSources)
    }

    func testDataStoreStampsSourceLabelOnMeterRowsOnly() async throws {
        let (provider, _) = makeProvider { request in
            switch request.url.path {
            case NineRouterUsageClient.statsPath: return response(statsJSON)
            case NineRouterUsageClient.chartPath: return response(chartJSON)
            case NineRouterUsageClient.providersPath: return response(connectionsJSON)
            case "/api/usage/claude-1": return response(claudeAccount1JSON)
            default: return response(#"{"quotas":{}}"#)
            }
        }
        let suite = "NineRouterProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors),
            providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        await store.refreshAll()

        let byID = Dictionary(uniqueKeysWithValues: provider.widgetDescriptors.map { ($0.id, $0) })
        XCTAssertEqual(store.data(for: try XCTUnwrap(byID["9router.session"])).sourceLabel, "Account 1")
        XCTAssertEqual(store.data(for: try XCTUnwrap(byID["9router.weekly"])).sourceLabel, "Account 1")
        XCTAssertNil(store.data(for: try XCTUnwrap(byID["9router.today"])).sourceLabel)
        let accountsRow = store.data(for: try XCTUnwrap(byID["9router.accounts"]))
        XCTAssertEqual(accountsRow.unboundedDetail, "3 active")
        XCTAssertEqual(accountsRow.gatewayAccounts.first?.name, "Account 1")
        XCTAssertFalse(try XCTUnwrap(byID["9router.accounts"]).pinnable)
    }

    func testRejectedTokenReportsInvalidToken() async {
        let (provider, _) = makeProvider { _ in response(#"{"error":"Unauthorized"}"#, status: 401) }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testServerDownReportsNetwork() async {
        let (provider, _) = makeProvider { _ in throw URLError(.cannotConnectToHost) }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testMissingInstallSkipsNetwork() async {
        let provider = NineRouterProvider(
            authStore: NineRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: NineRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without 9router installed")
                return response("{}")
            })
        )

        let snapshot = await provider.refresh()
        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertFalse(hasCredentials)
    }
}

// MARK: - Accounts

final class NineRouterAccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ hoursAgo: Double) -> String {
        OpenUsageISO8601.string(from: now.addingTimeInterval(-hoursAgo * 3600))
    }

    func testLocalAccountsCarryWindowsCostAndRoutingStateTightestFirst() {
        // Account 2 hit one 429: 9router locked a model for 16 seconds, then left the connection
        // `unavailable`. Its plan quota is almost untouched — the status must say "paused", not
        // anything that reads like a used-up limit.
        let connections = #"""
        {"connections":[
          {"id":"a","provider":"claude","name":"personal 5 max","isActive":true,"testStatus":"active"},
          {"id":"b","provider":"claude","name":"Account 2","isActive":true,"testStatus":"unavailable","errorCode":429,"lastErrorAt":"\#(iso(2))","modelLock_claude-opus-5-5":"\#(iso(1.99))","lastError":"[429] secret"},
          {"id":"c","provider":"deepseek","name":"localkey","isActive":true,"testStatus":"unavailable","errorCode":402},
          {"id":"e","provider":"glm","name":"GLM","isActive":true,"testStatus":"active","modelLock_glm-5":"\#(iso(-0.25))"},
          {"id":"d","provider":"openai-compatible-chat-886bd6e6","name":"off","isActive":false}
        ]}
        """#
        let usage: [String: Data] = [
            "a": Data(#"{"quotas":{"session (5h)":{"used":34,"total":100},"weekly (7d)":{"used":4,"total":100}}}"#.utf8),
            "b": Data(#"{"quotas":{"session (5h)":{"used":7,"total":100},"weekly (7d)":{"used":90,"total":100}}}"#.utf8),
            "c": Data(#"{"quotas":{"Balance (USD)":{"used":0,"total":0,"isCreditBalance":true}}}"#.utf8)
        ]
        let stats = Data(#"{"byAccount":{"m1 (claude - personal 5 max)":{"connectionId":"a","cost":10},"m2 (claude - personal 5 max)":{"connectionId":"a","cost":5},"m (claude - Account 2)":{"connectionId":"b","cost":7}}}"#.utf8)

        let accounts = NineRouterUsageMapper.localAccounts(
            connections: Data(connections.utf8), usageByID: usage, stats30: stats, now: now
        )

        // Quota-less accounts at equal cost fall back to name order: "GLM" before "localkey".
        XCTAssertEqual(accounts.map(\.id), ["b", "a", "e", "c"], "90% weekly first, then 34%, then quota-less")
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        XCTAssertEqual(byID["b"]?.status, .paused, "expired lock + unavailable = paused")
        XCTAssertEqual(byID["b"]?.errorCode, 429)
        XCTAssertEqual(byID["a"]?.status, .ok)
        XCTAssertEqual(byID["a"]?.cost30dUSD, 15)
        XCTAssertEqual(byID["c"]?.status, .noBalance)
        XCTAssertEqual(byID["e"]?.status, .coolingDown, "an unexpired lock is a short cooldown")
        XCTAssertNotNil(byID["e"]?.until)
        XCTAssertEqual(GatewayAccount.summary(accounts), "4 active · 3 need attention")
        XCTAssertTrue(byID["b"]?.statusDetail?.contains("plan quota is unaffected") == true)
    }

    func testSummaryNamesASingleKindOfProblem() {
        func account(_ status: GatewayAccount.Status) -> GatewayAccount {
            GatewayAccount(id: UUID().uuidString, name: "x", provider: nil, sessionPercent: nil,
                           weeklyPercent: nil, cost30dUSD: 0, status: status)
        }
        XCTAssertEqual(GatewayAccount.summary([account(.ok), account(.paused)]), "2 active · 1 paused")
        XCTAssertEqual(GatewayAccount.summary([account(.ok), account(.ok)]), "2 active")
    }

    func testProxyAccountsParseAndReorder() throws {
        let body = #"{"accounts":[{"id":"x","name":"","provider":"glm","sessionPercent":null,"weeklyPercent":null,"cost30dUSD":3,"status":"no_balance"},{"id":"y","name":"AI-TECH 2","provider":"claude","sessionPercent":39,"weeklyPercent":81,"cost30dUSD":100,"status":"paused","errorCode":429},{"id":"z","name":"old proxy","provider":"claude","cost30dUSD":1,"status":"rate_limited"}]}"#
        let accounts = try XCTUnwrap(NineRouterUsageMapper.proxyAccounts(Data(body.utf8)))
        XCTAssertEqual(accounts.map(\.id), ["y", "x", "z"])
        XCTAssertEqual(accounts[0].status, .paused)
        XCTAssertEqual(accounts[0].errorCode, 429)
        XCTAssertEqual(accounts[1].name, "glm", "an empty name falls back to the provider")
        XCTAssertEqual(accounts[1].status, .noBalance)
        XCTAssertEqual(accounts[2].status, .paused, "an older proxy's 'rate_limited' reads as paused")
        XCTAssertNil(NineRouterUsageMapper.proxyAccounts(Data("{}".utf8)))
    }

    func testAccountsLineReadsTheSummary() {
        let ok = GatewayAccount(id: "a", name: "A", provider: nil, sessionPercent: nil, weeklyPercent: nil, cost30dUSD: 0, status: .ok)
        guard case .badge(let label, let text, _, _) = NineRouterUsageMapper.accountsLine([ok, ok]) else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(label, "Accounts")
        XCTAssertEqual(text, "2 active")
        XCTAssertNil(NineRouterUsageMapper.accountsLine([]))
    }
}
