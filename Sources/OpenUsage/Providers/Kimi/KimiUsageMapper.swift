import Foundation

/// Builds metric lines from the Kimi for Coding `/coding/v1/usages` payload:
/// - top-level `usage` is the weekly request quota (used / limit, `resetTime`),
/// - each `limits[]` entry is a rolling rate-limit window (`window.duration` + `window.timeUnit`);
///   a sub-daily window is the session meter, a multi-day window the weekly fallback,
/// - `user.membership.level` (e.g. `LEVEL_STANDARD`) is a product enum, NOT the plan — the retail plan
///   name comes from `/coding/v1/me`'s `user_level_name` (e.g. "Vivace"), passed in separately.
///
/// All numeric fields arrive as strings (`"100"`); `ProviderParse.number` accepts both.
enum KimiUsageMapper {
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    static func map(body: Data, meBody: Data? = nil) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = meBody.flatMap(planName(fromMe:))
        guard let root = ProviderParse.jsonObject(body) else {
            throw KimiUsageError.invalidResponse
        }

        var lines: [MetricLine] = []

        if let windowLimits = root["limits"] as? [[String: Any]] {
            for entry in windowLimits {
                guard let (periodMs, line) = try windowLine(from: entry) else { continue }
                if periodMs < 24 * 60 * 60 * 1000 {
                    lines.append(try line("Session", periodMs))
                }
            }
        }

        if let usage = root["usage"] as? [String: Any] {
            lines.append(try quotaLine(usage, label: "Weekly", periodMs: weeklyPeriodMs))
        } else if let windowLimits = root["limits"] as? [[String: Any]] {
            for entry in windowLimits {
                guard let (periodMs, line) = try windowLine(from: entry) else { continue }
                if periodMs >= 24 * 60 * 60 * 1000 {
                    lines.append(try line("Weekly", periodMs))
                }
            }
        }

        guard !lines.isEmpty else {
            return (plan, [.noUsageData])
        }
        return (plan, lines)
    }

    // MARK: - Private

    /// `/me` `user_level_name` ("Vivace") is the retail plan name. Deliberately not
    /// `usages.user.membership.level`: that enum (LEVEL_STANDARD) is the coding product version, not the
    /// subscription tier — a Vivace account reports LEVEL_STANDARD there.
    private static func planName(fromMe body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body) else { return nil }
        return (root["user_level_name"] as? String)?.nilIfEmpty
    }

    /// A `limits[]` entry → `(periodMs, lineBuilder)`. The builder is deferred so the caller picks the
    /// label by window length (sub-daily = Session, multi-day = Weekly fallback).
    private static func windowLine(from entry: [String: Any]) throws -> (Int, (String, Int) throws -> MetricLine)? {
        guard let window = entry["window"] as? [String: Any],
              let detail = entry["detail"] as? [String: Any],
              let duration = ProviderParse.number(window["duration"]),
              duration > 0 else {
            return nil
        }
        let unitMs: Double
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_SECOND": unitMs = 1000
        case "TIME_UNIT_MINUTE": unitMs = 60 * 1000
        case "TIME_UNIT_HOUR": unitMs = 60 * 60 * 1000
        case "TIME_UNIT_DAY": unitMs = 24 * 60 * 60 * 1000
        default: return nil
        }
        let periodMs = Int(unitMs * duration)
        return (periodMs, { label, period in try quotaLine(detail, label: label, periodMs: period) })
    }

    private static func quotaLine(_ quota: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let used = ProviderParse.number(quota["used"]),
              let limit = ProviderParse.number(quota["limit"]),
              used >= 0, limit > 0 else {
            throw KimiUsageError.invalidResponse
        }
        let resetsAt = (quota["resetTime"] as? String).flatMap { OpenUsageISO8601.date(from: $0) }
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(used / limit * 100),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }
}
