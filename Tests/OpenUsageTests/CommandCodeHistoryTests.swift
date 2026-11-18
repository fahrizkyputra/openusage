import XCTest
@testable import OpenUsage

/// Command Code reports spend cumulatively since a start instant, never per day. Today is the reading
/// since the start of today; Yesterday is the difference between two cumulative readings.
@MainActor
final class CommandCodeHistoryTests: XCTestCase {
    nonisolated private static let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
    nonisolated private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    nonisolated private static var today: Date { utc.startOfDay(for: now) }
    nonisolated private static var yesterday: Date { utc.date(byAdding: .day, value: -1, to: today)! }

    nonisolated private static func summary(cost: Double, tokens: Int, requests: Int = 1) -> String {
        #"{"totalCount":\#(requests),"totalCost":\#(cost),"totalTokens":\#(tokens)}"#
    }

    /// since-today = $2.00 / 1000 tokens, since-yesterday = $2.50 / 1600 tokens.
    nonisolated private static func cumulative(_ request: HTTPRequest) -> HTTPResponse {
        let since = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "since" }?.value.flatMap(OpenUsageISO8601.date(from:))
        return since == today ? .json(summary(cost: 2.0, tokens: 1000)) : .json(summary(cost: 2.5, tokens: 1600))
    }

    private func source(
        periodStart: Date? = nil,
        _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse = { CommandCodeHistoryTests.cumulative($0) }
    ) -> (CommandCodeHistorySource, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        return (CommandCodeHistorySource(client: CommandCodeUsageClient(http: http), apiKey: "k", orgID: nil,
                                         periodStart: periodStart), http)
    }

    func testTodayIsTheCumulativeReadingAndYesterdayTheDifference() async {
        let (source, _) = source()

        let read = await source.read([Self.today, Self.yesterday], asOf: Self.now, calendar: Self.utc)

        XCTAssertEqual(read.days[Self.today]?.totals[.spend] ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(read.days[Self.today]?.totals[.tokens], 1000)
        XCTAssertEqual(read.days[Self.yesterday]?.totals[.spend] ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(read.days[Self.yesterday]?.totals[.tokens], 600)
        XCTAssertNil(read.rateLimitedFor)
    }

    func testADayBeforeTheBillingPeriodIsNotReturnedBecauseItWouldBeShort() async {
        // The period began at noon yesterday, so the API cannot see the start of yesterday.
        let (source, _) = source(periodStart: Self.yesterday.addingTimeInterval(12 * 3600))

        let read = await source.read([Self.today, Self.yesterday], asOf: Self.now, calendar: Self.utc)

        XCTAssertNotNil(read.days[Self.today])
        XCTAssertNil(read.days[Self.yesterday], "an unread day is absent, never a partial total")
    }

    func testAQuietDayIsAZeroDayNotAMissingOne() async {
        let (source, _) = source { _ in .json(Self.summary(cost: 0, tokens: 0, requests: 0)) }

        let read = await source.read([Self.today, Self.yesterday], asOf: Self.now, calendar: Self.utc)

        XCTAssertEqual(read.days[Self.today]?.totals[.spend], 0, "a range always shows, at 0")
        XCTAssertEqual(read.days[Self.yesterday]?.totals[.tokens], 0)
    }

    func testAnUnreadableTodayLeavesYesterdayUnreadToo() async {
        let (source, _) = source { _ in .json("{}", status: 500) }

        let read = await source.read([Self.today, Self.yesterday], asOf: Self.now, calendar: Self.utc)

        XCTAssertTrue(read.days.isEmpty, "yesterday is a difference, so it needs both readings")
    }

    func testARateLimitIsReportedSoTheLedgerCanWait() async {
        let (source, _) = source { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "40"], body: Data()) }

        let read = await source.read([Self.today], asOf: Self.now, calendar: Self.utc)

        XCTAssertEqual(read.rateLimitedFor, 40)
        XCTAssertTrue(read.days.isEmpty)
    }

    func testTheSourceRereadsHourlyInThePeriodsOwnCalendar() {
        let (source, _) = source()
        XCTAssertEqual(source.rereadInterval, 3600)
        XCTAssertEqual(source.calendar.timeZone, .current, "Command Code days follow this Mac's day")
    }

    func testTheCardShowsTodayAndYesterdayFromTheBilledReadings() async throws {
        let account = Account(kind: .commandcode, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("k"), for: account.id)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/alpha/whoami": return .json(#"{"success":true,"user":{"id":"u"},"org":null}"#)
            case "/alpha/billing/credits": return .json(#"{"credits":{"monthlyCredits":5}}"#)
            case "/alpha/billing/subscriptions": return .json(#"{"success":true,"data":{"status":"canceled"}}"#)
            default:
                let since = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "since" }?.value.flatMap(OpenUsageISO8601.date(from:))
                return since.map { $0 >= startOfToday.addingTimeInterval(-1) } == true
                    ? .json(Self.summary(cost: 2.0, tokens: 1000)) : .json(Self.summary(cost: 2.5, tokens: 1600))
            }
        }

        let snapshot = try await AccountProviderRuntime(account: account, vault: vault, http: http).refresh().get()

        guard case .values("Today", let today, _) = try XCTUnwrap(snapshot.line(label: "Today")),
              case .values("Yesterday", let yesterday, _) = try XCTUnwrap(snapshot.line(label: "Yesterday")) else {
            return XCTFail("Today and Yesterday rows")
        }
        XCTAssertEqual(today.first { $0.kind == .dollars }?.number, 2.0)
        XCTAssertEqual(yesterday.first { $0.kind == .dollars }?.number ?? 0, 0.5, accuracy: 0.0001)
    }
}
