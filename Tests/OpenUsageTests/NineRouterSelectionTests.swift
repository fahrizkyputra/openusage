import XCTest
@testable import OpenUsage

/// The rule the team's summary card uses to pick the ONE account whose Session and Weekly it shows.
/// Ported from 0.7 with its cases unchanged: this is behavior the team relies on.
final class NineRouterSelectionTests: XCTestCase {
    private func connection(
        _ name: String, session: Double?, weekly: Double?, status: KitchenConnection.Status = .ok,
        sessionReset: String? = nil, weeklyReset: String? = nil
    ) -> KitchenConnection {
        KitchenConnection(
            id: name.replacingOccurrences(of: " ", with: "_"), name: name, provider: "claude",
            sessionPercent: session, weeklyPercent: weekly,
            sessionResetsAt: sessionReset.flatMap(OpenUsageISO8601.date(from:)),
            weeklyResetsAt: weeklyReset.flatMap(OpenUsageISO8601.date(from:)),
            cost30dUSD: 0, status: status, until: nil, errorCode: nil)
    }

    private func chosen(_ connections: [KitchenConnection]) -> (session: Double?, weekly: Double?, name: String?) {
        let selection = NineRouterUsageMapper.selectedConnection(connections)
        return (selection?.sessionPercent, selection?.weeklyPercent, selection?.name)
    }

    func testPicksTheRoutableAccountWithTheLeastSessionLeft() {
        let result = chosen([
            connection("Account A", session: 40, weekly: 70),
            connection("Account B", session: 92, weekly: 10, status: .coolingDown),
            connection("Paused", session: 99, weekly: 95, status: .paused)
        ])
        XCTAssertEqual(result.name, "Account B", "paused is skipped; cooling down stays eligible")
        XCTAssertEqual(result.session, 92)
        XCTAssertEqual(result.weekly, 10, "Weekly comes from the same account, not the separate weekly maximum")
    }

    func testAnAccountWhoseWeeklyIsSpentIsSkippedForTheNextOne() {
        let result = chosen([
            connection("Weekly spent", session: 73, weekly: 100, status: .coolingDown),
            connection("Has room", session: 17, weekly: 21)
        ])
        XCTAssertEqual(result.name, "Has room")
        XCTAssertEqual(result.weekly, 21)
    }

    func testWhenEverySessionIsSpentTheSoonestSessionResetWins() {
        let result = chosen([
            connection("Later reset", session: 100, weekly: 95, sessionReset: "2026-09-30T13:00:00Z"),
            connection("Sooner reset", session: 100, weekly: 80, sessionReset: "2026-09-30T12:30:00Z")
        ])
        XCTAssertEqual(result.name, "Sooner reset")
        XCTAssertEqual(result.weekly, 80, "both bars follow the account whose Session resets first")
    }

    func testWhenEveryWeeklyIsSpentTheSoonestWeeklyResetWins() {
        let result = chosen([
            connection("Later weekly reset", session: 10, weekly: 100, weeklyReset: "2026-10-04T00:00:00Z"),
            connection("Sooner weekly reset", session: 50, weekly: 100, weeklyReset: "2026-10-03T00:00:00Z")
        ])
        XCTAssertEqual(result.name, "Sooner weekly reset")
    }

    func testWeeklyIsNeverBorrowedFromAnotherAccount() {
        let lines = NineRouterUsageMapper.summaryLines([
            connection("Session winner", session: 95, weekly: nil),
            connection("Weekly winner", session: 80, weekly: 90)
        ])
        XCTAssertEqual(lines.map(\.label), ["Session"], "the selected account reports no weekly, so there is no Weekly bar")
    }

    func testNoRoutableAccountWithASessionHidesBothBars() {
        let lines = NineRouterUsageMapper.summaryLines([
            connection("Paused", session: 90, weekly: 40, status: .paused),
            connection("No balance", session: 20, weekly: 10, status: .noBalance),
            connection("Weekly only", session: nil, weekly: 50)
        ])
        XCTAssertEqual(lines, [])
    }

    func testTheSummaryNamesTheAccountItShows() {
        let titles = NineRouterUsageMapper.summaryTitles([
            connection("AI-TECH - TEAM", session: 23, weekly: 57), connection("Other", session: 5, weekly: 5)
        ])
        XCTAssertEqual(titles["Session"], "Session · AI-TECH - TEAM")
        XCTAssertEqual(titles["Weekly"], "Weekly · AI-TECH - TEAM")
    }

    func testTheSameAccountIsChosenWhateverOrderTheServerListsThem() {
        let accounts = [
            connection("B", session: 50, weekly: 10), connection("A", session: 50, weekly: 10),
            connection("C", session: 49, weekly: 10)
        ]
        XCTAssertEqual(chosen(accounts).name, "A", "ties break by name, so the card never flips between refreshes")
        XCTAssertEqual(chosen(accounts.reversed()).name, "A")
    }
}
