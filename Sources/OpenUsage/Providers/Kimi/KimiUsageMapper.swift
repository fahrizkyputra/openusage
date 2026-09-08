import Foundation

/// Builds metric lines from the Kimi for Coding `/coding/v1/usages` payload:
/// - top-level `usage` is the weekly request quota (used / limit, `resetTime`),
/// - each `limits[]` entry is a rolling rate-limit window (`window.duration` + `window.timeUnit`);
///   a sub-daily window is the session meter, a multi-day window the weekly fallback,
/// - `user.membership.level` (e.g. `LEVEL_STANDARD`) becomes the plan name.
///
/// All numeric fields arrive as strings (`"100"`); `ProviderParse.number` accepts both.
enum KimiUsageMapper {
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    static func map(body: Data) throws -> (plan: String?, lines: [MetricLine]) {
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
            return (planName(from: root), [.noUsageData])
        }
        return (planName(from: root), lines)
    }

    // MARK: - Private

    /// `LEVEL_STANDARD` → `Standard`; unknown levels pass through title-cased minus the prefix.
    private static func planName(from root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = (membership["level"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        let trimmed = level.hasPrefix("LEVEL_") ? String(level.dropFirst("LEVEL_".count)) : level
        return trimmed.lowercased().titleCased(separator: { $0 == "_" })
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
