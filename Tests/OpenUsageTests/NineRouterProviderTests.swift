import XCTest
@testable import OpenUsage

private let machineID = "4f0c2b8e-machine"
private let cliSecret = "a1b2c3d4e5f6"

private let statsJSON = #"""
{"totalRequests":1613,"totalPromptTokens":1200000,"totalCompletionTokens":34000,"totalCachedTokens":596322,
 "totalCost":34.88,"byProvider":{"claude":{"requests":1613}},"byModel":{},"pending":{},"recentRequests":[]}
"""#

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
    func testSpendLineCarriesCostAndTokens() throws {
        let line = try XCTUnwrap(NineRouterUsageMapper.spendLine(label: "Today", body: data(statsJSON)))

        guard case .values(let label, let values, _, _, _, _) = line else { return XCTFail("expected values line") }
        XCTAssertEqual(label, "Today")
        XCTAssertEqual(values.first { $0.kind == .dollars }?.number, 34.88)
        XCTAssertEqual(values.first { $0.kind == .count }?.number, 1_234_000)
        XCTAssertFalse(values.contains { $0.estimated })
    }

    func testSpendLineRejectsNonStatsBody() {
        XCTAssertNil(NineRouterUsageMapper.spendLine(label: "Today", body: data(#"{"error":"Invalid period"}"#)))
    }

    func testActiveConnectionIDsSkipsInactive() {
        XCTAssertEqual(NineRouterUsageMapper.activeConnectionIDs(data(connectionsJSON)), ["claude-1", "claude-2", "glm-1"])
        XCTAssertNil(NineRouterUsageMapper.activeConnectionIDs(data("[]")))
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
        let quotas = NineRouterUsageMapper.quotas(data(claudeAccount1JSON)) + NineRouterUsageMapper.quotas(data(claudeAccount2JSON))

        let lines = NineRouterUsageMapper.tightestQuotaLines(quotas)

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
    }

    func testNoQuotasMeansNoMeters() {
        XCTAssertTrue(NineRouterUsageMapper.tightestQuotaLines([]).isEmpty)
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
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return (provider, http)
    }

    func testRefreshMapsSpendAndTightestQuotas() async throws {
        let (provider, http) = makeProvider { request in
            switch request.url.path {
            case NineRouterUsageClient.statsPath: return response(statsJSON)
            case NineRouterUsageClient.providersPath: return response(connectionsJSON)
            case "/api/usage/claude-1": return response(claudeAccount1JSON)
            case "/api/usage/claude-2": return response(claudeAccount2JSON)
            case "/api/usage/glm-1": return response(#"{"plan":"Unknown","quotas":{}}"#)
            default: return response("{}", status: 404)
            }
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Today", "Last 7 Days", "Last 30 Days"])
        let token = NineRouterAuthStore.cliToken(machineID: machineID, secret: cliSecret)
        XCTAssertTrue(http.requests.allSatisfy { $0.headers[NineRouterUsageClient.tokenHeader] == token })
        let periods = http.requests.filter { $0.url.path == NineRouterUsageClient.statsPath }
            .compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
        XCTAssertEqual(periods, ["today", "7d", "30d"])
        XCTAssertFalse(http.requests.contains { $0.url.path == "/api/usage/off-1" })
    }

    func testQuotaFailuresKeepSpendRows() async {
        let (provider, _) = makeProvider { request in
            if request.url.path == NineRouterUsageClient.statsPath { return response(statsJSON) }
            return response("{}", status: 500)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Today", "Last 7 Days", "Last 30 Days"])
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
