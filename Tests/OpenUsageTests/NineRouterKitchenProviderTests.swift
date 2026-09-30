import XCTest
@testable import OpenUsage

/// The proxy's /v1/daily: 30 server-local days ending on the fixed "today", day i costs i dollars.
private let dailyJSON: String = {
    let calendar = Calendar.current
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
    let days = (0..<30).map { i -> String in
        let day = calendar.date(byAdding: .day, value: -(29 - i), to: today)!
        return #"{"date":"\#(DailyUsageAccumulator.dayKey(from: day))","costUSD":\#(i),"tokens":\#(i * 100),"requests":\#(i)}"#
    }
    return #"{"timeZone":"\#(TimeZone.current.identifier)","days":[\#(days.joined(separator: ","))],"models":{"today":[{"model":"claude-opus-5-5","provider":"claude","costUSD":29,"tokens":2900}],"last30":[{"model":"claude-opus-5","provider":"claude","costUSD":400,"tokens":40000}]}}"#
}()

private let fixedNow = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
private let accountsJSON = #"{"accounts":[{"id":"k1","name":"Kitchen 1","provider":"claude","sessionPercent":40,"weeklyPercent":20,"cost30dUSD":12,"status":"ok"},{"id":"k2","name":"OR","provider":"openrouter","sessionPercent":null,"weeklyPercent":null,"cost30dUSD":3,"status":"paused","errorCode":429}]}"#
private let connectionsJSON = #"{"connections":[{"id":"k1","name":"Kitchen 1","provider":"claude","isActive":true}]}"#
private let quotaJSON = #"""
{"quotas":{"session (5h)":{"used":40,"total":100,"resetAt":"2026-09-29T10:00:00.000Z","unlimited":false,"isCreditBalance":false},
           "weekly (7d)":{"used":20,"total":100,"resetAt":"2026-10-03T00:00:00.000Z","unlimited":false,"isCreditBalance":false}}}
"""#

private func response(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
}

/// A fake kitchen-usage-proxy: accepts only `validKey`, serves the three read-only routes.
private final class FakeKitchenProxy: @unchecked Sendable {
    var validKey = "sk-team-key"
    var paths: [String] = []

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        XCTAssertEqual(request.url.host, "kitchen.example.com")
        XCTAssertNil(request.headers["Cookie"])
        XCTAssertNil(request.headers[NineRouterUsageClient.tokenHeader], "remote server must not get a CLI token")
        paths.append(request.url.path)
        guard request.headers["Authorization"] == "Bearer \(validKey)" else {
            return response(#"{"error":"invalid_api_key"}"#, status: 401)
        }
        switch request.url.path {
        case "/openusage/v1/daily":
            XCTAssertEqual(request.url.query, "days=30")
            return response(dailyJSON)
        case "/openusage/v1/connections": return response(connectionsJSON)
        case "/openusage/v1/accounts": return response(accountsJSON)
        case "/openusage/v1/connections/k1/usage": return response(quotaJSON)
        default: return response(#"{"error":"not_found"}"#, status: 404)
        }
    }
}

private let kitchenHost = "https://kitchen.example.com"

/// Auth store with the Kitchen host "baked into the build", as a packaged team build would have it.
private func kitchenStore(key: String?, environment: [String: String] = [:], bundled: String? = kitchenHost) -> NineRouterKitchenAuthStore {
    NineRouterKitchenAuthStore(files: keyFiles(key), environment: FakeEnvironment(environment), bundledBaseURL: bundled)
}

private func keyFiles(_ key: String?) -> FakeFiles {
    FakeFiles(key.map { [NineRouterKitchenAuthStore.configPaths[0]: #"{"apiKey":"\#($0)"}"#] } ?? [:])
}

final class NineRouterKitchenAuthStoreTests: XCTestCase {
    func testHostComesFromBuildAndEnvironmentOverridesIt() throws {
        XCTAssertEqual(try kitchenStore(key: nil).baseURL().absoluteString, "https://kitchen.example.com")

        let custom = kitchenStore(key: nil, environment: ["NINEROUTER_KITCHEN_URL": "https://other.example.com/"])
        XCTAssertEqual(try custom.baseURL().absoluteString, "https://other.example.com")
    }

    func testBundledCLIReadsHostFromContainingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("OpenUsage.app/Contents")
        let helper = contents.appendingPathComponent("Helpers/openusage")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data())
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.test", "CFBundlePackageType": "APPL",
            NineRouterKitchenAuthStore.infoPlistKey: "https://kitchen.example.com"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        // The test runner's own Bundle.main has no Kitchen key, like the CLI helper.
        XCTAssertEqual(NineRouterKitchenAuthStore.bundledBaseURL(executableURL: helper), "https://kitchen.example.com")
        XCTAssertNil(NineRouterKitchenAuthStore.bundledBaseURL(executableURL: root.appendingPathComponent("loose-binary")))
    }

    func testNoHostInSourceWhenUnconfigured() {
        let store = kitchenStore(key: nil, bundled: nil)
        XCTAssertNil(store.configuredBaseURL())
        XCTAssertThrowsError(try store.baseURL()) { error in
            XCTAssertEqual(error as? NineRouterKitchenAuthError, .notConfigured)
        }
        XCTAssertThrowsError(try kitchenStore(key: nil, bundled: "not a url").baseURL()) { error in
            XCTAssertEqual(error as? NineRouterKitchenAuthError, .invalidBaseURL)
        }
    }

    func testKeyComesFromConfigBeforeEnvironment() throws {
        let files = FakeFiles()
        let store = NineRouterKitchenAuthStore(
            files: files,
            environment: FakeEnvironment(["NINEROUTER_KITCHEN_API_KEY": "sk-env"]),
            bundledBaseURL: kitchenHost
        )
        XCTAssertEqual(store.loadAPIKey(), "sk-env")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)

        try store.saveAPIKey("  sk-saved  ")

        XCTAssertEqual(files.files[NineRouterKitchenAuthStore.configPaths[0]], #"{"apiKey":"sk-saved"}"#)
        XCTAssertEqual(store.loadAPIKey(), "sk-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }
}

@MainActor
final class NineRouterKitchenProviderTests: XCTestCase {
    private func makeProvider(proxy: FakeKitchenProxy, key: String? = "sk-team-key") -> NineRouterKitchenProvider {
        NineRouterKitchenProvider(
            authStore: kitchenStore(key: key),
            usageClient: NineRouterUsageClient(
                http: RoutingHTTPClient { proxy.handle($0) },
                routes: .proxy(basePath: NineRouterKitchenAuthStore.defaultProxyPath)
            ),
            now: { fixedNow }
        )
    }

    func testIsSeparateCardFromLocal9router() {
        let provider = makeProvider(proxy: FakeKitchenProxy())
        XCTAssertEqual(provider.provider.id, "9router-kitchen")
        XCTAssertEqual(provider.provider.displayName, "9router Kitchen")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), [
            "9router-kitchen.session", "9router-kitchen.weekly", "9router-kitchen.accounts", "9router-kitchen.trend",
            "9router-kitchen.today", "9router-kitchen.yesterday", "9router-kitchen.last30"
        ])
        XCTAssertEqual(provider.provider.links.first?.url, "https://kitchen.example.com/dashboard/usage")
        XCTAssertEqual(provider.apiKeyTitle, "API Key")
    }

    func testReadsUsageThroughProxyWithBearerKey() async {
        let proxy = FakeKitchenProxy()
        let provider = makeProvider(proxy: proxy)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Accounts", "Today", "Yesterday", "Last 30 Days", "Usage Trend"])
        XCTAssertEqual(snapshot.accounts?.map(\.name), ["Kitchen 1", "OR"])
        guard case .badge(_, let accountsText, _, _) = snapshot.line(label: "Accounts") else { return XCTFail("accounts row") }
        XCTAssertEqual(accountsText, "2 active · 1 paused")
        guard case .progress(_, let sessionUsed, _, _, let sessionReset, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("session meter")
        }
        XCTAssertEqual(sessionUsed, 40)
        XCTAssertEqual(sessionReset, OpenUsageISO8601.date(from: "2026-09-29T10:00:00.000Z"), "reset filled from the winning connection")
        XCTAssertEqual(snapshot.usageHistory?.series.daily.count, 30)
        guard case .values(_, let today, _, _, _, let todayModels) = snapshot.line(label: "Today"),
              case .values(_, let yesterday, _, _, _, _) = snapshot.line(label: "Yesterday"),
              case .values(_, _, _, _, _, let monthModels) = snapshot.line(label: "Last 30 Days") else {
            return XCTFail("expected spend tiles")
        }
        XCTAssertEqual(today.first { $0.kind == .dollars }?.number, 29)
        XCTAssertEqual(yesterday.first { $0.kind == .dollars }?.number, 28)
        XCTAssertEqual(todayModels?.models.map(\.model), ["claude-opus-5-5"])
        XCTAssertEqual(monthModels?.models.map(\.model), ["claude-opus-5"])
        XCTAssertEqual(snapshot.lineSources, ["Session": "Kitchen 1", "Weekly": "Kitchen 1"])
        XCTAssertEqual(Set(proxy.paths), [
            "/openusage/v1/daily", "/openusage/v1/accounts", "/openusage/v1/connections/k1/usage"
        ], "one accounts call + the winning connection's resets, not one call per connection")
        XCTAssertFalse(proxy.paths.contains { $0.hasPrefix("/api/") }, "must never call 9router admin routes")
    }

    func testRejectedKeyReportsInvalidKey() async {
        let proxy = FakeKitchenProxy()
        let provider = makeProvider(proxy: proxy, key: "sk-wrong")

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
        XCTAssertEqual(proxy.paths.count, 1, "stop after the first rejected call")
    }

    func testRateLimitAndProxyMisconfigurationHaveClearErrors() async {
        for (status, category) in [(429, ErrorCategory.rateLimited), (502, .http5xx)] {
            let provider = NineRouterKitchenProvider(
                authStore: kitchenStore(key: "sk-team-key"),
                usageClient: NineRouterUsageClient(
                    http: RoutingHTTPClient { _ in response(#"{"error":"x"}"#, status: status) },
                    routes: .proxy(basePath: "/openusage")
                )
            )
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, category, "HTTP \(status)")
        }
    }

    func testMissingKeySkipsNetwork() async {
        let provider = NineRouterKitchenProvider(
            authStore: kitchenStore(key: nil),
            usageClient: NineRouterUsageClient(
                http: RoutingHTTPClient { _ in
                    XCTFail("should not hit the network without a key")
                    return response("{}")
                },
                routes: .proxy(basePath: "/openusage")
            )
        )

        let snapshot = await provider.refresh()
        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertFalse(hasCredentials)
    }

    func testUnconfiguredBuildStaysOffAndHasNoLinks() async {
        let provider = NineRouterKitchenProvider(
            authStore: kitchenStore(key: "sk-team-key", bundled: nil),
            usageClient: NineRouterUsageClient(
                http: RoutingHTTPClient { _ in
                    XCTFail("no host, no network")
                    return response("{}")
                },
                routes: .proxy(basePath: "/openusage")
            )
        )

        let snapshot = await provider.refresh()
        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertFalse(hasCredentials, "a key alone must not auto-enable an unconfigured card")
        XCTAssertTrue(provider.provider.links.isEmpty)
    }

    func testUnreachableServerNamesKitchen() async {
        let provider = NineRouterKitchenProvider(
            authStore: kitchenStore(key: "sk-team-key"),
            usageClient: NineRouterUsageClient(
                http: RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) },
                routes: .proxy(basePath: "/openusage")
            )
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return XCTFail("expected error badge") }
        XCTAssertTrue(text.contains("9router Kitchen"))
    }

    func testConnectionIDCannotAddPathSegments() async throws {
        let http = RoutingHTTPClient { _ in response(#"{"quotas":{}}"#) }
        let client = NineRouterUsageClient(http: http, routes: .proxy(basePath: "/openusage"))
        let auth = NineRouterAuth(baseURL: URL(string: "https://kitchen.example.com")!, credential: .apiKey("k"))

        _ = try await client.fetchConnectionUsage(connectionID: "../../api/keys", auth: auth)

        let url = try XCTUnwrap(http.requests.first?.url)
        XCTAssertEqual(url.absoluteString, "https://kitchen.example.com/openusage/v1/connections/%2E%2E%2F%2E%2E%2Fapi%2Fkeys/usage")
    }
}
