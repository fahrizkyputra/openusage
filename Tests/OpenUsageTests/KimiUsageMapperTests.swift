import XCTest
@testable import OpenUsage

/// Mapper tests against a captured live `/coding/v1/usages` response (LEVEL_STANDARD plan, anonymized).
final class KimiUsageMapperTests: XCTestCase {
    private let liveUsages = #"""
    {
      "user": {"userId": "abc123", "region": "REGION_OVERSEA", "membership": {"level": "LEVEL_STANDARD"}},
      "usage": {"limit": "100", "used": "40", "remaining": "60", "resetTime": "2026-09-09T15:30:57.459681Z"},
      "limits": [
        {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
         "detail": {"limit": "100", "used": "12", "remaining": "88", "resetTime": "2026-09-08T10:30:57.459681Z"}}
      ],
      "parallel": {"limit": "30"}
    }
    """#

    private let liveMe = #"{"user_id": "abc123", "nickname": "User", "user_level": 30, "user_level_name": "Vivace"}"#

    func testMapsLiveResponseToSessionAndWeeklyMeters() throws {
        let usage = try KimiUsageMapper.map(body: Data(liveUsages.utf8), meBody: Data(liveMe.utf8))

        XCTAssertEqual(usage.plan, "Vivace", "the retail plan comes from /me, not membership.level")
        XCTAssertEqual(usage.lines.map(\.label), ["Session", "Weekly"])
        guard case .progress("Session", let sessionUsed, 100, .percent, let sessionResets, let sessionPeriod) = usage.lines[0] else {
            return XCTFail("session meter")
        }
        XCTAssertEqual(sessionUsed, 12, accuracy: 0.001)
        XCTAssertEqual(sessionPeriod, 300 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(sessionResets).timeIntervalSince1970, 1_788_863_457.459681, accuracy: 0.001)
        guard case .progress("Weekly", let weeklyUsed, 100, .percent, let weeklyResets, let weeklyPeriod) = usage.lines[1] else {
            return XCTFail("weekly meter")
        }
        XCTAssertEqual(weeklyUsed, 40, accuracy: 0.001)
        XCTAssertEqual(weeklyPeriod, 7 * 24 * 60 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(weeklyResets).timeIntervalSince1970, 1_788_967_857.459681, accuracy: 0.001)
    }

    func testMissingUsageSectionStillShowsSession() throws {
        let body = #"{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"50","used":"25"}}]}"#
        let usage = try KimiUsageMapper.map(body: Data(body.utf8), meBody: nil)
        XCTAssertEqual(usage.lines.map(\.label), ["Session"])
        guard case .progress(_, let used, _, _, _, let period) = usage.lines[0] else { return XCTFail("progress line") }
        XCTAssertEqual(used, 50, accuracy: 0.001)
        XCTAssertEqual(period, 5 * 60 * 60 * 1000)
    }

    func testAMultiDayWindowIsTheWeeklyFallbackWhenThereIsNoTopLevelUsage() throws {
        let body = #"{"limits":[{"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"200","used":"50"}}]}"#
        let usage = try KimiUsageMapper.map(body: Data(body.utf8), meBody: nil)
        XCTAssertEqual(usage.lines.map(\.label), ["Weekly"])
        guard case .progress(_, 25, _, _, _, let period) = usage.lines[0] else { return XCTFail("weekly fallback") }
        XCTAssertEqual(period, 7 * 24 * 60 * 60 * 1000)
    }

    func testWithoutMeBodyPlanIsNilButMetersStillMap() throws {
        let usage = try KimiUsageMapper.map(body: Data(liveUsages.utf8), meBody: nil)
        XCTAssertNil(usage.plan)
        XCTAssertEqual(usage.lines.count, 2)
    }

    func testPlanIsTheProductLevelNeverTheMembershipEnum() throws {
        let usage = try KimiUsageMapper.map(body: Data(liveUsages.utf8), meBody: Data(#"{"user_level_name":""}"#.utf8))
        XCTAssertNil(usage.plan, "an empty level name is no plan; LEVEL_STANDARD must not stand in for it")
    }

    func testGarbageBodyIsAnInvalidResponse() {
        XCTAssertThrowsError(try KimiUsageMapper.map(body: Data("not json".utf8), meBody: nil)) {
            XCTAssertEqual($0 as? ProviderError, .invalidResponse)
        }
    }

    func testAnAccountWithNoQuotaSectionsSaysSoInsteadOfShowingNothing() {
        XCTAssertThrowsError(try KimiUsageMapper.map(body: Data(#"{"user":{}}"#.utf8), meBody: nil)) {
            XCTAssertEqual($0 as? ProviderError, .unavailable("Kimi reports no quota for this account."))
        }
    }

    func testAMalformedQuotaThrowsInsteadOfReadingAsZero() {
        for body in [#"{"usage":{"limit":"0","used":"1"}}"#, #"{"usage":{"limit":"10","used":"-1"}}"#] {
            XCTAssertThrowsError(try KimiUsageMapper.map(body: Data(body.utf8), meBody: nil), body) {
                XCTAssertEqual($0 as? ProviderError, .invalidResponse)
            }
        }
    }

    func testUsedAboveTheLimitClampsToFullRatherThanOverflowing() throws {
        let body = #"{"usage":{"limit":"10","used":"25"}}"#
        let usage = try KimiUsageMapper.map(body: Data(body.utf8), meBody: nil)
        guard case .progress("Weekly", 100, _, _, _, _) = usage.lines[0] else { return XCTFail("clamped to 100%") }
    }
}
