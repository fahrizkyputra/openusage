import XCTest
@testable import OpenUsage

// Real /v1/accounts and /v1/daily shapes, five connections as the live server answers.
private let summaryAccounts = #"""
{"accounts":[
  {"id":"c1","name":"AI-TECH 2 - TEAM","provider":"claude","sessionPercent":100,"weeklyPercent":72,
   "sessionResetAt":"2026-11-18T05:10:00.000Z","weeklyResetAt":"2026-11-22T13:00:00.000Z","cost30dUSD":4200,"status":"paused","errorCode":429},
  {"id":"c2","name":"AI-TECH 2 - PERSONAL MAX 20","provider":"claude","sessionPercent":null,"weeklyPercent":91,
   "weeklyResetAt":"2026-11-21T01:00:00.000Z","cost30dUSD":120,"status":"ok"},
  {"id":"c3","name":"AI-TECH - TEAM","provider":"claude","sessionPercent":23,"weeklyPercent":57,
   "sessionResetAt":"2026-11-18T07:00:00.000Z","weeklyResetAt":"2026-11-23T02:00:00.000Z","cost30dUSD":2500,"status":"ok"},
  {"id":"c4","name":"claude-cli-jeff","provider":"anthropic-compatible-5b9b0d90","cost30dUSD":0,"status":"ok"},
  {"id":"c5","name":"Free Model","provider":"openrouter","cost30dUSD":0,"status":"ok"}
]}
"""#

@MainActor
final class NineRouterSummaryCardTests: XCTestCase {
    nonisolated private static func daily() -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: Date())
        let days = (0..<30).map { offset -> String in
            let day = utc.date(byAdding: .day, value: -(29 - offset), to: today)!
            let formatter = DateFormatter()
            formatter.calendar = utc
            formatter.timeZone = utc.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let key = formatter.string(from: day)
            return #"{"date":"\#(key)","costUSD":\#(offset),"tokens":\#(offset * 100),"requests":\#(offset)}"#
        }
        return #"{"timeZone":"UTC","days":[\#(days.joined(separator: ","))],"models":{"today":[],"last30":[]}}"#
    }

    private func refresh(
        upstream: String? = nil, _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async throws -> (Result<ProviderSnapshot, RefreshFailure>, RoutingHTTPClient) {
        let account = Account(kind: .ninerouterKitchen, label: "Team", upstream: upstream)
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("sk-team"), for: account.id)
        let http = RoutingHTTPClient(handler: handler)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http,
                                             kitchenHost: URL(string: "https://kitchen.example.com")!)
        return (await runtime.refresh(), http)
    }

    nonisolated private static func live(_ request: HTTPRequest) -> HTTPResponse {
        request.url.path.hasSuffix("/daily") ? .json(daily()) : .json(summaryAccounts)
    }

    func testTheSummaryShowsTheChosenAccountTheAccountCountAndTheSpendRows() async throws {
        let (result, _) = try await refresh { Self.live($0) }

        let snapshot = try result.get()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Accounts", "Today", "Yesterday", "Last 30 Days"])
        guard case .progress("Session", 23, _, _, _, _) = try XCTUnwrap(snapshot.line(label: "Session")),
              case .progress("Weekly", 57, _, _, _, _) = try XCTUnwrap(snapshot.line(label: "Weekly")) else {
            return XCTFail("the 23% / 57% account, both bars from the same one (the 100% one is paused)")
        }
        XCTAssertEqual(snapshot.lineTitles?["Session"], "Session · AI-TECH - TEAM")
        XCTAssertEqual(snapshot.lineTitles?["Weekly"], "Weekly · AI-TECH - TEAM")
        guard case .badge("Accounts", let text) = try XCTUnwrap(snapshot.line(label: "Accounts")) else { return XCTFail("badge") }
        XCTAssertEqual(text, "5 active · 1 paused")
    }

    func testSpendComesFromTheServersDaysAndMatchesItsCost() async throws {
        let (result, _) = try await refresh { Self.live($0) }

        let snapshot = try result.get()
        guard case .values("Today", let today, _) = try XCTUnwrap(snapshot.line(label: "Today")),
              case .values("Last 30 Days", let month, _) = try XCTUnwrap(snapshot.line(label: "Last 30 Days")) else {
            return XCTFail("spend rows")
        }
        XCTAssertEqual(today.first { $0.kind == .dollars }?.number, 29, "the server's last day costs 29 in the fixture")
        XCTAssertEqual(month.first { $0.kind == .dollars }?.number, (0..<30).reduce(0, +).doubleValue, "the 30 server days, summed")
    }

    func testEveryAccountPausedHidesBothBarsButKeepsTheCountAndTheSpend() async throws {
        let paused = #"{"accounts":[{"id":"a","name":"A","provider":"claude","sessionPercent":90,"weeklyPercent":40,"status":"paused"}]}"#
        let (result, _) = try await refresh { $0.url.path.hasSuffix("/daily") ? .json(Self.daily()) : .json(paused) }

        let snapshot = try result.get()
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Accounts"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testAFailedDailyReadStillShowsTheMetersAndTheCount() async throws {
        let (result, _) = try await refresh { $0.url.path.hasSuffix("/daily") ? .json("{}", status: 502) : .json(summaryAccounts) }

        let snapshot = try result.get()
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Accounts"))
        XCTAssertNil(snapshot.line(label: "Today"), "no daily answer, no spend row")
    }

    func testARejectedKeyIsNamedAndNothingElseIsSent() async throws {
        let (result, http) = try await refresh { _ in .json(#"{"error":"invalid_api_key"}"#, status: 401) }

        guard case .failure(let failure) = result else { return XCTFail("a 401 must fail") }
        XCTAssertEqual(failure.message, "9router Kitchen rejected the API key. Replace it on the account's page.")
        XCTAssertEqual(http.requests.map(\.url.path), ["/openusage/v1/accounts"], "the daily read is not sent with a refused key")
    }

    func testAConnectionCardForAConnectionTheServerNoLongerListsSaysSo() async throws {
        let (result, _) = try await refresh(upstream: "gone") { Self.live($0) }

        guard case .failure(let failure) = result else { return XCTFail("a vanished connection cannot read") }
        XCTAssertEqual(failure.message, "This connection is no longer on the server.")
    }

    func testTheKeyIsOnlyEverSentToTheBuildsHost() async throws {
        let (_, http) = try await refresh { Self.live($0) }

        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "kitchen.example.com" })
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk-team" })
        XCTAssertTrue(http.requests.allSatisfy { $0.url.path.hasPrefix("/openusage/v1/") }, "never a 9router admin route")
    }
}

private extension Int { var doubleValue: Double { Double(self) } }
