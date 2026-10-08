import XCTest
@testable import OpenUsage

// Captured `/coding/v1/usages` and `/coding/v1/me` shapes (values trimmed).
private let kimiUsagesJSON = #"""
{
  "user": {"userId": "abc123", "region": "REGION_OVERSEA", "membership": {"level": "LEVEL_STANDARD"}},
  "usage": {"limit": "100", "used": "40", "remaining": "60", "resetTime": "2026-09-09T15:30:57.000Z"},
  "limits": [
    {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
     "detail": {"limit": "100", "used": "12", "remaining": "88", "resetTime": "2026-09-08T10:30:57.000Z"}}
  ],
  "parallel": {"limit": "30"}
}
"""#

private let kimiMeJSON = #"{"user_id": "abc123", "nickname": "User", "user_level": 30, "user_level_name": "Vivace"}"#

private let kimiNow = OpenUsageISO8601.date(from: "2026-09-09T12:00:00.000Z")!

private func kimiResponse(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
}

@MainActor
final class KimiProviderTests: XCTestCase {
    /// A provider with no local harness sources: an empty pi session directory and no OpenCode database,
    /// so a test never reads the machine's real logs.
    private func makeProvider(
        key: String? = "sk-kimi-test",
        environment: [String: String] = [:],
        handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse
    ) -> (KimiProvider, RoutingHTTPClient) {
        let http = RoutingHTTPClient { try handler($0) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let provider = KimiProvider(
            authStore: KimiAuthStore(
                files: FakeFiles(key.map { [KimiAuthStore.configPaths[0]: #"{"apiKey":"\#($0)"}"#] } ?? [:]),
                environment: FakeEnvironment(environment)
            ),
            usageClient: KimiUsageClient(http: http),
            piUsageScanner: PiUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { home }),
            openCodeUsageScanner: OpenCodeKimiUsageScanner(sqlite: KeyValueSQLite(), databasePaths: { [] }),
            pricing: { .empty },
            now: { kimiNow }
        )
        return (provider, http)
    }

    nonisolated private static func liveHandler(_ request: HTTPRequest) -> HTTPResponse {
        XCTAssertEqual(request.url.host, "api.kimi.com")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-kimi-test")
        switch request.url.path {
        case "/coding/v1/usages": return kimiResponse(kimiUsagesJSON)
        case "/coding/v1/me": return kimiResponse(kimiMeJSON)
        default: return kimiResponse(#"{"error":"not_found"}"#, status: 404)
        }
    }

    func testRefreshMapsSessionAndWeeklyMetersWithPlan() async {
        let (provider, http) = makeProvider(handler: Self.liveHandler)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Vivace")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        guard case .progress("Session", let sessionUsed, 100, .percent, let sessionReset, let period, _) = snapshot.lines[0] else {
            return XCTFail("session meter")
        }
        XCTAssertEqual(sessionUsed, 12, accuracy: 0.001)
        XCTAssertEqual(period, 300 * 60 * 1000)
        XCTAssertEqual(sessionReset, OpenUsageISO8601.date(from: "2026-09-08T10:30:57.000Z"))
        guard case .progress("Weekly", let weeklyUsed, 100, _, _, _, _) = snapshot.lines[1] else {
            return XCTFail("weekly meter")
        }
        XCTAssertEqual(weeklyUsed, 40, accuracy: 0.001)
        XCTAssertEqual(http.requests.map(\.url.path), ["/coding/v1/usages", "/coding/v1/me"])
    }

    func testPlanLookupFailureStillRendersTheMeters() async {
        let (provider, _) = makeProvider { request in
            request.url.path == "/coding/v1/me"
                ? kimiResponse(#"{"error":"boom"}"#, status: 500)
                : Self.liveHandler(request)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    func testMissingKeySkipsNetworkAndClassifiesAsNotLoggedIn() async {
        let (provider, http) = makeProvider(key: nil) { _ in
            XCTFail("no key, no request")
            return kimiResponse("{}")
        }

        let snapshot = await provider.refresh()
        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(hasCredentials)
    }

    func testRejectedKeyStopsAfterTheFirstCall() async {
        let (provider, http) = makeProvider { _ in kimiResponse(#"{"error":"unauthorized"}"#, status: 401) }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testHTTPStatusesMapToTheirCategories() async {
        for (status, category) in [(429, ErrorCategory.rateLimited), (400, .http4xx), (500, .http5xx)] {
            let (provider, _) = makeProvider { _ in kimiResponse(#"{"error":"x"}"#, status: status) }

            let snapshot = await provider.refresh()

            XCTAssertEqual(snapshot.errorCategory, category, "HTTP \(status)")
        }
    }

    func testMalformedQuotaBodyIsDecodingAndTransportFailureIsNetwork() async {
        let (malformed, _) = makeProvider { _ in kimiResponse("not json") }
        let (unreachable, _) = makeProvider { _ in throw URLError(.notConnectedToInternet) }

        let malformedSnapshot = await malformed.refresh()
        let unreachableSnapshot = await unreachable.refresh()

        XCTAssertEqual(malformedSnapshot.errorCategory, .decoding)
        XCTAssertEqual(unreachableSnapshot.errorCategory, .network)
    }

    func testKeyComesFromConfigFileBeforeEnvironment() throws {
        let files = FakeFiles()
        let store = KimiAuthStore(files: files, environment: FakeEnvironment(["KIMI_API_KEY": "sk-env"]))

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-env")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)

        try store.saveAPIKey("  sk-saved  ")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)

        try store.deleteAPIKey()

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-env", "clearing the saved key falls back to the environment")
    }

    func testCardIsSpendCapableWithAMachineLocalHistoryScope() {
        let descriptors = KimiProvider().widgetDescriptors
        XCTAssertEqual(descriptors.filter(\.isSpendTile).map(\.metricLabel), ["Today", "Yesterday", "Last 30 Days"])
        XCTAssertEqual(descriptors.compactMap(\.historyResource).map(\.scope), [.machineLocal])
    }
}
