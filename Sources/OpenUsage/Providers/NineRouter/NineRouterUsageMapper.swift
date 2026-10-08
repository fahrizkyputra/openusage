import Foundation

/// Normalizes 9router's dashboard API payloads into OpenUsage metric lines.
///
/// Spend rows come from `NineRouterDailyUsage`; this mapper handles the plan quotas.
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

    /// Kitchen's two headline meters follow one account: choose the routable account with the least
    /// Session remaining (highest Session percent below 100). If all routable Session windows are
    /// exhausted, choose the one that resets soonest. Weekly comes only from that selected account.
    /// Paused / no-balance / auth-error connections aren't candidates; cooling-down connections remain
    /// eligible because 9router can route other models through them.
    static func kitchenQuotaLines(_ accounts: [GatewayAccount])
        -> (lines: [MetricLine], sources: [String: String]) {
        let eligible = accounts.filter {
            ($0.status == .ok || $0.status == .coolingDown) && $0.sessionPercent != nil
        }
        let available = eligible.filter { ($0.sessionPercent ?? 100) < 100 }
        let selected: GatewayAccount?
        if !available.isEmpty {
            selected = available.sorted { lhs, rhs in
                if lhs.sessionPercent != rhs.sessionPercent {
                    return (lhs.sessionPercent ?? 0) > (rhs.sessionPercent ?? 0)
                }
                let leftReset = lhs.sessionResetsAt ?? .distantFuture
                let rightReset = rhs.sessionResetsAt ?? .distantFuture
                if leftReset != rightReset { return leftReset < rightReset }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }.first
        } else {
            selected = eligible.sorted { lhs, rhs in
                let leftReset = lhs.sessionResetsAt ?? .distantFuture
                let rightReset = rhs.sessionResetsAt ?? .distantFuture
                if leftReset != rightReset { return leftReset < rightReset }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }.first
        }
        guard let selected, let session = selected.sessionPercent else { return ([], [:]) }

        var lines = [MetricLine.progress(label: "Session", used: session, limit: 100, format: .percent,
                                         resetsAt: selected.sessionResetsAt, periodDurationMs: sessionPeriodMs)]
        var sources = ["Session": selected.name]
        if let weekly = selected.weeklyPercent {
            lines.append(.progress(label: "Weekly", used: weekly, limit: 100, format: .percent,
                                   resetsAt: selected.weeklyResetsAt, periodDurationMs: weeklyPeriodMs))
            sources["Weekly"] = selected.name
        }
        return (lines, sources)
    }

    /// The tightest Session and Weekly meters across every connection's quotas, plus the connection
    /// each came from (keyed by line label, for `ProviderSnapshot.lineSources`). Ties keep the window
    /// that resets sooner, since it frees up first. Used by the local 9router card.
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

    // MARK: - Accounts

    /// A connection's routing state in 9router: an unexpired `modelLock_*` is cooling down; a
    /// connection 9router marked `unavailable`/`error` is paused (or no balance / auth error by its last
    /// code); otherwise OK. Mirrors kitchen-usage-proxy's `accountStatus`.
    static func accountStatus(_ connection: [String: Any], now: Date)
        -> (status: GatewayAccount.Status, until: Date?, errorCode: Int?) {
        let lockEnds = connection
            .filter { $0.key.hasPrefix("modelLock_") }
            .compactMap { ($0.value as? String).flatMap(OpenUsageISO8601.date(from:)) }
            .filter { $0 > now }
        if let until = lockEnds.max() { return (.coolingDown, until, nil) }
        let test = connection["testStatus"] as? String
        guard test == "unavailable" || test == "error" else { return (.ok, nil, nil) }
        let code = ProviderParse.number(connection["errorCode"]).map(Int.init)
        switch code {
        case 402: return (.noBalance, nil, nil)
        case 401, 403: return (.authError, nil, nil)
        default: return (.paused, nil, code)
        }
    }

    /// Every active connection from the local gateway's own routes: `/api/providers` (names, status),
    /// each `/api/usage/<id>` (windows), and `stats?period=30d` `byAccount` (cost).
    static func localAccounts(
        connections body: Data,
        usageByID: [String: Data],
        stats30: Data?,
        now: Date
    ) -> [GatewayAccount] {
        guard let raw = ProviderParse.jsonObject(body)?["connections"] as? [[String: Any]] else { return [] }
        let names = Dictionary(uniqueKeysWithValues: (activeConnections(body) ?? []).map { ($0.id, $0.name) })
        var costByID: [String: Double] = [:]
        if let stats30, let byAccount = ProviderParse.jsonObject(stats30)?["byAccount"] as? [String: Any] {
            for case let entry as [String: Any] in byAccount.values {
                if let id = entry["connectionId"] as? String, let cost = ProviderParse.number(entry["cost"]) {
                    costByID[id, default: 0] += cost
                }
            }
        }
        let accounts = raw.compactMap { connection -> GatewayAccount? in
            guard (connection["isActive"] as? Bool) != false, let id = connection["id"] as? String,
                  let name = names[id] else { return nil }
            let windows = usageByID[id].map { quotas($0) } ?? []
            let state = accountStatus(connection, now: now)
            let session = windows.filter { $0.window == .session }.max { $0.percent < $1.percent }
            let weekly = windows.filter { $0.window == .weekly }.max { $0.percent < $1.percent }
            return GatewayAccount(
                id: id,
                name: name,
                provider: connection["provider"] as? String,
                sessionPercent: session?.percent,
                weeklyPercent: weekly?.percent,
                sessionResetsAt: session?.resetsAt,
                weeklyResetsAt: weekly?.resetsAt,
                cost30dUSD: max(0, costByID[id] ?? 0),
                status: state.status,
                until: state.until,
                errorCode: state.errorCode
            )
        }
        return GatewayAccount.ordered(accounts)
    }

    /// kitchen-usage-proxy's `/openusage/v1/accounts` body.
    static func proxyAccounts(_ body: Data) -> [GatewayAccount]? {
        guard let list = ProviderParse.jsonObject(body)?["accounts"] as? [[String: Any]] else { return nil }
        let accounts = list.compactMap { entry -> GatewayAccount? in
            guard let id = entry["id"] as? String else { return nil }
            let provider = entry["provider"] as? String
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return GatewayAccount(
                id: id,
                name: name ?? provider ?? id,
                provider: provider,
                sessionPercent: ProviderParse.number(entry["sessionPercent"]).map(ProviderParse.clampPercent),
                weeklyPercent: ProviderParse.number(entry["weeklyPercent"]).map(ProviderParse.clampPercent),
                sessionResetsAt: (entry["sessionResetAt"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                weeklyResetsAt: (entry["weeklyResetAt"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                cost30dUSD: max(0, ProviderParse.number(entry["cost30dUSD"]) ?? 0),
                // An older proxy's labels (`rate_limited`, `error`) predate the routing states; read
                // them as paused so they never claim quota is used up.
                status: (entry["status"] as? String).flatMap(GatewayAccount.Status.init(rawValue:)) ?? .paused,
                until: (entry["until"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                errorCode: ProviderParse.number(entry["errorCode"]).map(Int.init)
            )
        }
        return GatewayAccount.ordered(accounts)
    }

    /// The card's "Accounts" row: "4 active · 1 paused".
    static func accountsLine(_ accounts: [GatewayAccount]) -> MetricLine? {
        guard !accounts.isEmpty else { return nil }
        return .badge(label: GatewayAccount.lineLabel, text: GatewayAccount.summary(accounts))
    }
}
