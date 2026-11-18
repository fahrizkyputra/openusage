import XCTest
@testable import OpenUsage

private let ccWhoami = #"{"success":true,"user":{"id":"u1","name":"N","email":"e@example.com","userName":"n"},"org":null}"#
private let ccCredits = #"""
{"credits":{"monthlyCredits":20.25,"purchasedCredits":3,"freeCredits":1.5},
 "windowLimits":{"limited":true,
   "fiveHour":{"used":1.19,"cap":14,"resetAt":1790930159548},
   "weekly":{"used":3.9,"cap":35,"resetAt":1791114669043}}}
"""#
private let ccSubscription = #"{"success":true,"data":{"status":"active","planId":"individual-goat","currentPeriodStart":"2026-09-09T04:59:00.000Z","currentPeriodEnd":"2026-10-09T04:59:00.000Z"}}"#
private let ccSummary = #"{"totalCount":5484,"totalCost":49.77,"totalTokens":1561483358}"#

@MainActor
final class CommandCodeProviderTests: XCTestCase {
    nonisolated private static func live(_ request: HTTPRequest) -> HTTPResponse {
        switch request.url.path {
        case "/alpha/whoami": .json(ccWhoami)
        case "/alpha/billing/credits": .json(ccCredits)
        case "/alpha/billing/subscriptions": .json(ccSubscription)
        case "/alpha/usage/summary": .json(ccSummary)
        default: .json(#"{"error":"not_found"}"#, status: 404)
        }
    }

    private func refresh(
        _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async throws -> (Result<ProviderSnapshot, RefreshFailure>, RoutingHTTPClient) {
        let account = Account(kind: .commandcode, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("user_key"), for: account.id)
        let http = RoutingHTTPClient(handler: handler)
        return (await AccountProviderRuntime(account: account, vault: vault, http: http).refresh(), http)
    }

    func testARefreshBuildsTheCardFromTheFourReads() async throws {
        let (result, http) = try await refresh { Self.live($0) }

        let snapshot = try result.get()
        XCTAssertEqual(snapshot.plan, "GOAT")
        XCTAssertEqual(snapshot.lines.map(\.label), ["5-hour", "Weekly", "Monthly", "Extra credits", "Requests"])
        XCTAssertEqual(Set(http.requests.map(\.url.path)), [
            "/alpha/whoami", "/alpha/billing/credits", "/alpha/billing/subscriptions", "/alpha/usage/summary"
        ])
        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "api.commandcode.ai" })
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer user_key" })
        XCTAssertTrue(http.requests.allSatisfy { $0.method == "GET" })
    }

    func testTheRequestCountIsReadFromTheBillingPeriodStart() async throws {
        let (_, http) = try await refresh { Self.live($0) }

        let summary = try XCTUnwrap(http.requests.first { $0.url.path == "/alpha/usage/summary" })
        let since = URLComponents(url: summary.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value
        XCTAssertEqual(since.flatMap(OpenUsageISO8601.date(from:)), OpenUsageISO8601.date(from: "2026-09-09T04:59:00.000Z"))
    }

    func testAnOrganizationSeatScopesTheBillingReads() async throws {
        let (_, http) = try await refresh { request in
            request.url.path == "/alpha/whoami" ? .json(#"{"success":true,"user":{"id":"u1"},"org":{"id":"org_9"}}"#) : Self.live(request)
        }

        let scoped = http.requests.filter { $0.url.path != "/alpha/whoami" }
        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.allSatisfy { $0.url.query?.contains("orgId=org_9") == true })
        let whoami = try XCTUnwrap(http.requests.first { $0.url.path == "/alpha/whoami" })
        XCTAssertEqual(whoami.url.query, "limits=1", "who-am-I runs before the org is known, so it carries no orgId")
    }

    func testARejectedKeyStopsAfterWhoamiAndNamesTheKey() async throws {
        let (result, http) = try await refresh { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }

        guard case .failure(let failure) = result else { return XCTFail("a 401 must fail") }
        XCTAssertEqual(failure.message, "Command Code rejected the API key. Replace it on the account's page.")
        XCTAssertEqual(http.requests.count, 1, "no further read is sent with a refused key")
    }

    func testAFailedPlanOrRequestReadStillShowsTheMeters() async throws {
        let (result, _) = try await refresh { request in
            switch request.url.path {
            case "/alpha/billing/subscriptions", "/alpha/usage/summary": .json("{}", status: 500)
            default: Self.live(request)
            }
        }

        let snapshot = try result.get()
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines.map(\.label), ["5-hour", "Weekly", "Extra credits"], "no Monthly or Requests without them")
    }

    func testRateLimitIsReportedAsAWaitNotARefusedKey() async throws {
        let (result, _) = try await refresh { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "30"], body: Data()) }

        guard case .failure(let failure) = result else { return XCTFail("a 429 must fail") }
        XCTAssertEqual(failure.kind, .rateLimited(retryAfter: 30))
    }

    func testTheDescriptorsMatchTheLinesTheMapperEmits() {
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: Account(kind: .commandcode, label: "Work"))
        XCTAssertEqual(descriptors.map(\.metricLabel), ["5-hour", "Weekly", "Monthly", "Extra credits", "Requests"])
    }
}
