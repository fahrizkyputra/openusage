import XCTest
@testable import OpenUsage

// Shapes captured from kitchen-usage-proxy (/openusage/v1/accounts), values trimmed.
private let kitchenAccountsJSON = #"""
{"accounts":[
  {"id":"c1","name":"AI-TECH 2 - TEAM","provider":"claude","sessionPercent":100,"weeklyPercent":72,
   "sessionResetAt":"2026-11-18T05:10:00.500Z","weeklyResetAt":"2026-11-22T13:00:00.000Z","cost30dUSD":4200.5,"status":"paused","until":null,"errorCode":429},
  {"id":"c2","name":"AI-TECH 2 - PERSONAL MAX 20","provider":"claude","sessionPercent":null,"weeklyPercent":91,
   "sessionResetAt":null,"weeklyResetAt":"2026-11-21T01:00:00.000Z","cost30dUSD":120,"status":"ok","until":null,"errorCode":null},
  {"id":"c3","name":"","provider":"openrouter","sessionPercent":null,"weeklyPercent":null,
   "sessionResetAt":null,"weeklyResetAt":null,"cost30dUSD":0,"status":"cooling_down","until":"2026-11-18T06:00:00.000Z","errorCode":null}
]}
"""#

final class NineRouterUsageMapperTests: XCTestCase {
    func testConnectionsAreReadWithTheirWindowsResetsAndStatus() throws {
        let connections = try XCTUnwrap(NineRouterUsageMapper.connections(Data(kitchenAccountsJSON.utf8)))

        XCTAssertEqual(connections.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(connections[0].status, .paused)
        XCTAssertEqual(connections[0].errorCode, 429)
        XCTAssertEqual(connections[0].sessionPercent, 100)
        XCTAssertEqual(connections[0].sessionResetsAt, OpenUsageISO8601.date(from: "2026-11-18T05:10:00.500Z"))
        XCTAssertEqual(connections[0].weeklyResetsAt, OpenUsageISO8601.date(from: "2026-11-22T13:00:00.000Z"))
        XCTAssertEqual(connections[0].cost30dUSD, 4200.5)
        XCTAssertNil(connections[1].sessionPercent, "a weekly-only account has no session window")
        XCTAssertEqual(connections[1].weeklyPercent, 91)
        XCTAssertEqual(connections[2].status, .coolingDown)
        XCTAssertEqual(connections[2].until, OpenUsageISO8601.date(from: "2026-11-18T06:00:00.000Z"))
        XCTAssertEqual(connections[2].name, "openrouter", "an empty name falls back to the provider")
    }

    func testAnOlderProxysLabelsReadAsPausedNotAsUsedUpQuota() throws {
        let body = #"{"accounts":[{"id":"a","name":"A","provider":"claude","status":"rate_limited"},{"id":"b","name":"B","provider":"claude","status":"error"}]}"#
        let connections = try XCTUnwrap(NineRouterUsageMapper.connections(Data(body.utf8)))
        XCTAssertEqual(connections.map(\.status), [.paused, .paused])
    }

    func testPercentsAreClampedAndABodyWithoutAccountsIsRejected() throws {
        let body = #"{"accounts":[{"id":"a","name":"A","provider":"claude","sessionPercent":140,"weeklyPercent":-5,"status":"ok"}]}"#
        let connection = try XCTUnwrap(NineRouterUsageMapper.connections(Data(body.utf8))?.first)
        XCTAssertEqual(connection.sessionPercent, 100)
        XCTAssertEqual(connection.weeklyPercent, 0)
        XCTAssertNil(NineRouterUsageMapper.connections(Data("{}".utf8)))
        XCTAssertNil(NineRouterUsageMapper.connections(Data("not json".utf8)))
    }

    func testAnEntryWithAnUnsafeIDIsDropped() throws {
        let body = #"{"accounts":[{"id":"../../api/keys","name":"x","provider":"claude","status":"ok"},{"id":"good_1-2","name":"y","provider":"claude","status":"ok"}]}"#
        let connections = try XCTUnwrap(NineRouterUsageMapper.connections(Data(body.utf8)))
        XCTAssertEqual(connections.map(\.id), ["good_1-2"], "an id can never add a path segment")
    }

    func testAConnectionCardShowsItsWindowsAndThirtyDayCost() throws {
        let connections = try XCTUnwrap(NineRouterUsageMapper.connections(Data(kitchenAccountsJSON.utf8)))

        let usage = NineRouterUsageMapper.connectionUsage(connections[0])

        XCTAssertEqual(usage.lines.map(\.label), ["Session", "Weekly", "Cost 30 Days"])
        guard case .progress("Session", 100, 100, .percent, let reset, let period) = usage.lines[0] else { return XCTFail("session") }
        XCTAssertEqual(reset, OpenUsageISO8601.date(from: "2026-11-18T05:10:00.500Z"))
        XCTAssertEqual(period, NineRouterUsageMapper.sessionPeriodMs)
        guard case .values("Cost 30 Days", let cost, _) = usage.lines[2] else { return XCTFail("cost") }
        XCTAssertEqual(cost.first?.number, 4200.5)
        XCTAssertEqual(NineRouterUsageMapper.connectionUsage(connections[1]).lines.map(\.label), ["Weekly", "Cost 30 Days"],
                       "no session window, no session bar")
        XCTAssertEqual(NineRouterUsageMapper.connectionUsage(connections[2]).lines.map(\.label), [],
                       "an account with no quota and no cost shows nothing to read")
    }

    func testSummaryTextNamesASingleKindOfProblemOrSaysNeedAttention() throws {
        let one = try XCTUnwrap(NineRouterUsageMapper.connections(Data(
            #"{"accounts":[{"id":"a","name":"A","provider":"c","status":"ok"},{"id":"b","name":"B","provider":"c","status":"paused"}]}"#.utf8)))
        XCTAssertEqual(NineRouterUsageMapper.summary(one), "2 active · 1 paused")
        let many = try XCTUnwrap(NineRouterUsageMapper.connections(Data(kitchenAccountsJSON.utf8)))
        XCTAssertEqual(NineRouterUsageMapper.summary(many), "3 active · 2 need attention")
        XCTAssertEqual(NineRouterUsageMapper.summary(Array(one.prefix(1))), "1 active")
    }
}
