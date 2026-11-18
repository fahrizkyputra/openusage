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

@MainActor
final class KimiProviderTests: XCTestCase {
    nonisolated private static func live(_ request: HTTPRequest) -> HTTPResponse {
        switch request.url.path {
        case "/coding/v1/usages": .json(kimiUsagesJSON)
        case "/coding/v1/me": .json(kimiMeJSON)
        default: .json(#"{"error":"not_found"}"#, status: 404)
        }
    }

    private func refresh(
        _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async throws -> (Result<ProviderSnapshot, RefreshFailure>, RoutingHTTPClient) {
        let account = Account(kind: .kimi, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("sk-kimi-test"), for: account.id)
        let http = RoutingHTTPClient(handler: handler)
        return (await AccountProviderRuntime(account: account, vault: vault, http: http).refresh(), http)
    }

    func testARefreshShowsSessionWeeklyAndThePlan() async throws {
        let (result, http) = try await refresh { Self.live($0) }

        let snapshot = try result.get()
        XCTAssertEqual(snapshot.plan, "Vivace")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(http.requests.map(\.url.path), ["/coding/v1/usages", "/coding/v1/me"])
        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "api.kimi.com" })
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk-kimi-test" })
        XCTAssertTrue(http.requests.allSatisfy { $0.method == "GET" })
    }

    func testAFailedPlanLookupStillRendersTheMeters() async throws {
        let (result, _) = try await refresh { request in
            request.url.path == "/coding/v1/me" ? .json(#"{"error":"boom"}"#, status: 500) : Self.live(request)
        }

        let snapshot = try result.get()
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    func testARejectedKeyStopsAfterTheFirstCall() async throws {
        let (result, http) = try await refresh { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }

        guard case .failure(let failure) = result else { return XCTFail("a 401 must fail") }
        XCTAssertEqual(failure.message, "Kimi rejected the API key. Replace it on the account's page.")
        XCTAssertEqual(http.requests.count, 1, "the plan lookup is not sent with a refused key")
    }

    func testRateLimitIsAWaitNotARefusedKey() async throws {
        let (result, _) = try await refresh { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "30"], body: Data()) }

        guard case .failure(let failure) = result else { return XCTFail("a 429 must fail") }
        XCTAssertEqual(failure.kind, .rateLimited(retryAfter: 30))
    }

    func testAMalformedBodyIsRefusedRatherThanShownAsZero() async throws {
        let (result, _) = try await refresh { _ in .json("not json") }

        guard case .failure(let failure) = result else { return XCTFail("garbage must fail") }
        XCTAssertEqual(failure.kind, .refused)
    }

    func testTheDescriptorsMatchTheLinesTheMapperEmits() {
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: Account(kind: .kimi, label: "Work"))
        XCTAssertEqual(descriptors.map(\.metricLabel), ["Session", "Weekly"])
        XCTAssertEqual(Set(descriptors.flatMap(\.limitResources).map(\.key)), ["session", "weekly"])
    }
}
