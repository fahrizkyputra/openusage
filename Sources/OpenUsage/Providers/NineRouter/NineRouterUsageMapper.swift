import Foundation

/// One upstream connection behind a 9router Kitchen, as kitchen-usage-proxy reports it.
struct KitchenConnection: Equatable, Sendable {
    /// How 9router is treating the connection right now, not how long ago it last failed: cooling down
    /// (a model lock runs), paused (it stopped routing here after an error), or refused (no balance, or the
    /// upstream rejected 9router's credentials).
    enum Status: String, Sendable {
        case ok
        case coolingDown = "cooling_down"
        case paused
        case noBalance = "no_balance"
        case authError = "auth_error"

        var isProblem: Bool { self != .ok }
        var label: String {
            switch self {
            case .ok: "OK"
            case .coolingDown: "Cooling down"
            case .paused: "Paused"
            case .noBalance: "No balance"
            case .authError: "Auth error"
            }
        }
    }

    var id: String
    var name: String
    var provider: String?
    var sessionPercent: Double?
    var weeklyPercent: Double?
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
    var cost30dUSD: Double
    var status: Status
    var until: Date?
    var errorCode: Int?
}

enum NineRouterUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// `/v1/accounts`: nil when the body is not an accounts payload. An entry whose id is not a plain token
    /// is dropped, so an id can never add a path segment to a later request. A status an older proxy
    /// sent (`rate_limited`, `error`) reads as paused: it never claims the plan quota is used up.
    static func connections(_ body: Data) -> [KitchenConnection]? {
        guard let list = ProviderParse.jsonObject(body)?["accounts"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
            else { return nil }
            let provider = entry["provider"] as? String
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return KitchenConnection(
                id: id,
                name: name ?? provider ?? id,
                provider: provider,
                sessionPercent: ProviderParse.number(entry["sessionPercent"]).map(ProviderParse.clampPercent),
                weeklyPercent: ProviderParse.number(entry["weeklyPercent"]).map(ProviderParse.clampPercent),
                sessionResetsAt: date(entry["sessionResetAt"]),
                weeklyResetsAt: date(entry["weeklyResetAt"]),
                cost30dUSD: max(0, ProviderParse.number(entry["cost30dUSD"]) ?? 0),
                status: (entry["status"] as? String).flatMap(KitchenConnection.Status.init(rawValue:)) ?? .paused,
                until: date(entry["until"]),
                errorCode: ProviderParse.number(entry["errorCode"]).map(Int.init)
            )
        }
    }

    /// A connection's own card: its windows and what it cost over 30 days. A window it does not report is
    /// absent, not zero.
    static func connectionUsage(_ connection: KitchenConnection) -> ProviderUsage {
        var lines: [MetricLine] = []
        if let session = connection.sessionPercent {
            lines.append(.progress(label: "Session", used: session, limit: 100, format: .percent,
                                   resetsAt: connection.sessionResetsAt, periodDurationMs: sessionPeriodMs))
        }
        if let weekly = connection.weeklyPercent {
            lines.append(.progress(label: "Weekly", used: weekly, limit: 100, format: .percent,
                                   resetsAt: connection.weeklyResetsAt, periodDurationMs: weeklyPeriodMs))
        }
        if connection.cost30dUSD > 0 {
            lines.append(.values(label: "Cost 30 Days", values: [MetricValue(number: connection.cost30dUSD, kind: .dollars)]))
        }
        return ProviderUsage(plan: nil, lines: lines)
    }

    /// "4 active · 1 paused": the problem's name when every problem is one kind, else "need attention".
    static func summary(_ connections: [KitchenConnection]) -> String {
        let base = "\(connections.count) active"
        let problems = connections.filter(\.status.isProblem)
        guard !problems.isEmpty else { return base }
        let kinds = Set(problems.map(\.status))
        let word = kinds.count == 1 ? kinds.first!.label.lowercased() : "need attention"
        return "\(base) · \(problems.count) \(word)"
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(OpenUsageISO8601.date(from:))
    }
}
