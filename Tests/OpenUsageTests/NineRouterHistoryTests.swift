import XCTest
@testable import OpenUsage

/// /v1/daily keys its days in the SERVER's calendar (UTC here), which is not this Mac's: a Mac at +07:00
/// has already begun the next day for seven hours of every UTC day.
@MainActor
final class NineRouterHistoryTests: XCTestCase {
    nonisolated private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    nonisolated private static let now = ISO8601DateFormatter().date(from: "2026-11-18T20:00:00Z")!   // 03:00 next day at +07:00

    nonisolated private static let dailyJSON = #"""
    {"timeZone":"UTC","days":[
      {"date":"2026-11-16","costUSD":10,"tokens":1000,"requests":3},
      {"date":"2026-11-17","costUSD":20,"tokens":2000,"requests":4},
      {"date":"2026-11-18","costUSD":30,"tokens":3000,"requests":5}],
     "models":{"today":[{"model":"claude-opus-5-5","provider":"claude","costUSD":29,"tokens":2900}],"last30":[]}}
    """#

    private func source(_ json: String = NineRouterHistoryTests.dailyJSON, status: Int = 200) -> NineRouterHistorySource {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8)) }
        return NineRouterHistorySource(client: NineRouterUsageClient(http: http, baseURL: URL(string: "https://kitchen.example.com")!), apiKey: "k")
    }

    private func day(_ offset: Int) -> Date { Self.utc.date(byAdding: .day, value: -offset, to: Self.utc.startOfDay(for: Self.now))! }

    func testDaysAreKeyedInTheServersCalendarNotThisMacs() async {
        let read = await source().read([day(0), day(1), day(2)], asOf: Self.now, calendar: Self.utc)

        XCTAssertEqual(read.days[day(0)]?.totals[.spend], 30)
        XCTAssertEqual(read.days[day(1)]?.totals[.tokens], 2000)
        XCTAssertEqual(read.days[day(2)]?.totals[.spend], 10)
        XCTAssertNil(read.rateLimitedFor)
    }

    func testTheSourceDeclaresTheServersZoneAsItsCalendar() {
        XCTAssertEqual(source().calendar.timeZone.identifier, "UTC")
        XCTAssertEqual(source().rereadInterval, 3600)
    }

    func testADayTheServerNamesNothingForIsAZeroDayInsideTheWindow() async {
        let read = await source().read([day(0), day(5)], asOf: Self.now, calendar: Self.utc)

        XCTAssertEqual(read.days[day(5)]?.totals[.spend], 0, "inside the 30 days the server answered, quiet is zero")
    }

    func testAFailedOrMalformedReadLeavesEveryDayUnread() async {
        let failed = await source(status: 502).read([day(0)], asOf: Self.now, calendar: Self.utc)
        XCTAssertTrue(failed.days.isEmpty)
        let garbage = await source("not json").read([day(0)], asOf: Self.now, calendar: Self.utc)
        XCTAssertTrue(garbage.days.isEmpty)
        let badDate = await source(#"{"days":[{"date":"yesterday","costUSD":1,"tokens":1}]}"#).read([day(0)], asOf: Self.now, calendar: Self.utc)
        XCTAssertTrue(badDate.days.isEmpty, "a body with a bad date is rejected whole, never partly used")
    }

    func testARateLimitIsReportedSoTheLedgerWaits() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "20"], body: Data()) }
        let source = NineRouterHistorySource(client: NineRouterUsageClient(http: http, baseURL: URL(string: "https://kitchen.example.com")!), apiKey: "k")

        let read = await source.read([day(0)], asOf: Self.now, calendar: Self.utc)

        XCTAssertEqual(read.rateLimitedFor, 20)
    }

    func testTheClientAsksForThirtyDaysWithTheBearerKeyOnTheBuildsHost() async {
        let http = RoutingHTTPClient { _ in .json(Self.dailyJSON) }
        let source = NineRouterHistorySource(client: NineRouterUsageClient(http: http, baseURL: URL(string: "https://kitchen.example.com")!), apiKey: "sk-k")

        _ = await source.read([day(0)], asOf: Self.now, calendar: Self.utc)

        let request = http.requests.first
        XCTAssertEqual(request?.url.absoluteString, "https://kitchen.example.com/openusage/v1/daily?days=30")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer sk-k")
        XCTAssertNil(request?.headers["x-9r-cli-token"], "a remote server never gets a local CLI token")
    }
}
