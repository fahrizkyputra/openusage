import XCTest
@testable import OpenUsage

/// Mapper tests against a captured live `/coding/v1/usages` response (LEVEL_STANDARD plan,
/// anonymized). Run with `swift test --filter KimiUsage`.
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

    func testMapsLiveResponseToSessionAndWeeklyMeters() throws {
        let (plan, lines) = try KimiUsageMapper.map(body: Data(liveUsages.utf8))
        XCTAssertEqual(plan, "Standard")
        XCTAssertEqual(lines.count, 2)

        let session = lines[0]
        XCTAssertEqual(session.label, "Session")
        guard case .progress(_, let sessionUsed, let sessionLimit, _, let sessionResets, let sessionPeriod, _) = session else {
            return XCTFail("expected session progress line, got \(session)")
        }
        XCTAssertEqual(sessionUsed, 12, accuracy: 0.001)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionPeriod, 300 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(sessionResets).timeIntervalSince1970, 1_788_863_457.459681, accuracy: 0.001)

        let weekly = lines[1]
        XCTAssertEqual(weekly.label, "Weekly")
        guard case .progress(_, let weeklyUsed, _, _, let weeklyResets, let weeklyPeriod, _) = weekly else {
            return XCTFail("expected weekly progress line, got \(weekly)")
        }
        XCTAssertEqual(weeklyUsed, 40, accuracy: 0.001)
        XCTAssertEqual(weeklyPeriod, 7 * 24 * 60 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(weeklyResets).timeIntervalSince1970, 1_788_967_857.459681, accuracy: 0.001)
    }

    func testMissingUsageSectionStillShowsSession() throws {
        let body = #"{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"50","used":"25"}}]}"#
        let (_, lines) = try KimiUsageMapper.map(body: Data(body.utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].label, "Session")
        guard case .progress(_, let used, _, _, _, let period, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(used, 50, accuracy: 0.001)
        XCTAssertEqual(period, 5 * 60 * 60 * 1000)
    }

    func testGarbageBodyThrows() {
        XCTAssertThrowsError(try KimiUsageMapper.map(body: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }

    func testMalformedQuotaThrows() {
        let body = #"{"usage":{"limit":"0","used":"1"}}"#
        XCTAssertThrowsError(try KimiUsageMapper.map(body: Data(body.utf8)))
    }
}
