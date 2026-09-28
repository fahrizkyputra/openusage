import Foundation

/// Normalizes 9router's dashboard API payloads into OpenUsage metric lines.
///
/// - `/api/usage/stats?period=…` → one combined "cost · tokens" row per period. The cost is the one
///   9router itself computes per request, so it is not marked as a local estimate.
/// - `/api/usage/<connectionId>` → the plan quotas 9router reads from each upstream account. 9router
///   rotates requests across connections, so OpenUsage shows the **tightest** Session and Weekly window
///   across all active connections — the one that will throttle you first.
enum NineRouterUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    enum Window: Equatable {
        case session
        case weekly
    }

    /// One bounded quota window reported for a connection.
    struct Quota: Equatable, Sendable {
        var window: Window
        var percent: Double
        var resetsAt: Date?
    }

    // MARK: - Stats

    /// A combined spend row from a `/api/usage/stats` payload, or nil when the body isn't a stats object.
    static func spendLine(label: String, body: Data) -> MetricLine? {
        guard let root = ProviderParse.jsonObject(body),
              let cost = ProviderParse.number(root["totalCost"]) else { return nil }
        let prompt = ProviderParse.number(root["totalPromptTokens"]) ?? 0
        let completion = ProviderParse.number(root["totalCompletionTokens"]) ?? 0
        return .values(label: label, values: [
            MetricValue(number: max(0, cost), kind: .dollars),
            MetricValue(number: max(0, prompt + completion), kind: .count, label: "tokens")
        ])
    }

    // MARK: - Connections

    /// IDs of active connections from `/api/providers`, in 9router's order. Nil when the body is malformed.
    static func activeConnectionIDs(_ body: Data) -> [String]? {
        guard let root = ProviderParse.jsonObject(body),
              let connections = root["connections"] as? [[String: Any]] else { return nil }
        return connections.compactMap { connection in
            guard (connection["isActive"] as? Bool) != false,
                  let id = connection["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }

    /// Session / Weekly quota windows from one `/api/usage/<connectionId>` payload. Credit balances,
    /// unlimited entries, and model-specific windows (e.g. `weekly fable (7d)`) are skipped: only the
    /// account-wide Session and Weekly windows feed the headline meters.
    static func quotas(_ body: Data) -> [Quota] {
        guard let root = ProviderParse.jsonObject(body),
              let quotas = root["quotas"] as? [String: Any] else { return [] }
        return quotas.compactMap { name, value in
            guard let entry = value as? [String: Any],
                  let window = window(forQuotaName: name),
                  (entry["unlimited"] as? Bool) != true,
                  (entry["isCreditBalance"] as? Bool) != true,
                  let used = ProviderParse.number(entry["used"]),
                  let total = ProviderParse.number(entry["total"]), total > 0 else { return nil }
            let resetsAt = (entry["resetAt"] as? String).flatMap(OpenUsageISO8601.date(from:))
            return Quota(window: window, percent: ProviderParse.clampPercent(used / total * 100), resetsAt: resetsAt)
        }
    }

    /// `session`, `Session (5h)` → session; `weekly`, `Weekly (7d)` → weekly. Anything with extra words
    /// between the window name and its parenthesised duration is a model-specific window.
    static func window(forQuotaName name: String) -> Window? {
        var base = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let paren = base.firstIndex(of: "(") {
            base = String(base[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        switch base {
        case "session": return .session
        case "weekly": return .weekly
        default: return nil
        }
    }

    /// The tightest Session and Weekly meters across every connection's quotas. Ties keep the window
    /// that resets sooner, since it frees up first.
    static func tightestQuotaLines(_ quotas: [Quota]) -> [MetricLine] {
        let windows: [(window: Window, label: String, periodMs: Int)] = [
            (.session, "Session", sessionPeriodMs),
            (.weekly, "Weekly", weeklyPeriodMs)
        ]
        return windows.compactMap { window, label, period in
            let candidates = quotas.filter { $0.window == window }
            guard let tightest = candidates.max(by: { lhs, rhs in
                if lhs.percent != rhs.percent { return lhs.percent < rhs.percent }
                return (lhs.resetsAt ?? .distantFuture) > (rhs.resetsAt ?? .distantFuture)
            }) else { return nil }
            return .progress(
                label: label,
                used: tightest.percent,
                limit: 100,
                format: .percent,
                resetsAt: tightest.resetsAt,
                periodDurationMs: period
            )
        }
    }
}
