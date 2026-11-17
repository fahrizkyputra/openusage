import XCTest
@testable import OpenUsage

/// Team builds ship with telemetry off: no PostHog setup, no daily ping, no crash reports.
@MainActor
final class TeamTelemetryTests: XCTestCase {
    func testTheTeamSinkDropsEveryEvent() {
        let sink = TeamTelemetrySink()
        sink.capture("app_daily_active", ["install_id": "x"])
        sink.capture("provider_accounts_daily", ["providers": ["claude": 1]])
        sink.flush()
        XCTAssertEqual(sink.capturedCount, 0, "nothing is retained or sent")
    }

    func testTheBuildCarriesNoPostHogProjectToken() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenUsage/Services/Telemetry.swift"), encoding: .utf8)
        XCTAssertNil(source.range(of: ##"token = "phc_[A-Za-z0-9]{30,}""##, options: .regularExpression),
                     "the upstream PostHog token must not be baked into a team build")
    }
}
