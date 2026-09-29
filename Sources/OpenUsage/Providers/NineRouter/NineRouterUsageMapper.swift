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

    /// One active upstream connection: its id and the name shown next to a meter it wins.
    struct Connection: Equatable, Sendable {
        var id: String
        var name: String
    }

    /// One bounded quota window reported for a connection.
    struct Quota: Equatable, Sendable {
        var window: Window
        var percent: Double
        var resetsAt: Date?
        /// Display name of the connection that reported it (e.g. "Account 1").
        var source: String? = nil
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

    /// Active connections from `/api/providers`, in 9router's order. Nil when the body is malformed.
    /// Each is named by its 9router label ("Account 1"); a name shared by several active connections
    /// gets its provider appended ("Account 1 (claude)") so the meter's source stays unambiguous.
    static func activeConnections(_ body: Data) -> [Connection]? {
        guard let root = ProviderParse.jsonObject(body),
              let raw = root["connections"] as? [[String: Any]] else { return nil }
        let active: [(id: String, name: String?, provider: String?)] = raw.compactMap { connection in
            guard (connection["isActive"] as? Bool) != false,
                  let id = connection["id"] as? String, !id.isEmpty else { return nil }
            let name = (connection["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return (id, name, connection["provider"] as? String)
        }
        let nameCounts = active.reduce(into: [String: Int]()) { counts, entry in
            if let name = entry.name { counts[name, default: 0] += 1 }
        }
        return active.map { entry in
            guard let name = entry.name else {
                return Connection(id: entry.id, name: entry.provider ?? entry.id)
            }
            let isShared = (nameCounts[name] ?? 0) > 1
            return Connection(id: entry.id, name: isShared ? "\(name) (\(entry.provider ?? entry.id))" : name)
        }
    }

    /// Session / Weekly quota windows from one `/api/usage/<connectionId>` payload. Credit balances,
    /// unlimited entries, and model-specific windows (e.g. `weekly fable (7d)`) are skipped: only the
    /// account-wide Session and Weekly windows feed the headline meters.
    static func quotas(_ body: Data, source: String? = nil) -> [Quota] {
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
            return Quota(window: window, percent: ProviderParse.clampPercent(used / total * 100),
                         resetsAt: resetsAt, source: source)
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

    /// The tightest Session and Weekly meters across every connection's quotas, plus the connection
    /// each came from (keyed by line label, for `ProviderSnapshot.lineSources`). Ties keep the window
    /// that resets sooner, since it frees up first.
    static func tightestQuotas(_ quotas: [Quota]) -> (lines: [MetricLine], sources: [String: String]) {
        let windows: [(window: Window, label: String, periodMs: Int)] = [
            (.session, "Session", sessionPeriodMs),
            (.weekly, "Weekly", weeklyPeriodMs)
        ]
        var lines: [MetricLine] = []
        var sources: [String: String] = [:]
        for (window, label, period) in windows {
            let candidates = quotas.filter { $0.window == window }
            guard let tightest = candidates.max(by: { lhs, rhs in
                if lhs.percent != rhs.percent { return lhs.percent < rhs.percent }
                return (lhs.resetsAt ?? .distantFuture) > (rhs.resetsAt ?? .distantFuture)
            }) else { continue }
            lines.append(.progress(
                label: label,
                used: tightest.percent,
                limit: 100,
                format: .percent,
                resetsAt: tightest.resetsAt,
                periodDurationMs: period
            ))
            sources[label] = tightest.source
        }
        return (lines, sources)
    }
}
