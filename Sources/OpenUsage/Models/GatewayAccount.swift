import Foundation

/// One upstream account behind a gateway card (a 9router connection): its plan windows, 30-day cost,
/// and health. Rendered by the card's "Accounts" row and its hover list.
struct GatewayAccount: Hashable, Sendable, Codable {
    /// Metric-line label of the card row that lists the accounts.
    static let lineLabel = "Accounts"

    /// The account's routing state in the gateway — whether 9router will send requests to it right
    /// now — not how long ago it last errored. Plan quota is separate (Session / Weekly).
    enum Status: String, Hashable, Sendable, Codable {
        case ok
        /// A model lock is still running; 9router skips this model on the account until `until`.
        case coolingDown = "cooling_down"
        /// 9router stopped routing to it after an error (`errorCode`); a connection test in the
        /// 9router dashboard brings it back.
        case paused
        case noBalance = "no_balance"
        case authError = "auth_error"

        var label: String {
            switch self {
            case .ok: "OK"
            case .coolingDown: "Cooling down"
            case .paused: "Paused"
            case .noBalance: "No balance"
            case .authError: "Auth error"
            }
        }

        var isProblem: Bool { self != .ok }
    }

    var id: String
    var name: String
    var provider: String?
    var sessionPercent: Double?
    var weeklyPercent: Double?
    var cost30dUSD: Double
    var status: Status
    /// End of the running model lock (`coolingDown` only).
    var until: Date? = nil
    /// Last HTTP status the gateway saw from this account (`paused` only).
    var errorCode: Int? = nil

    /// Hover text explaining the status, or nil for OK.
    var statusDetail: String? {
        switch status {
        case .ok: nil
        case .coolingDown:
            until.map { "9router skips one model on this account until \(Formatters.resetAbsoluteLabel(at: $0, now: Date()))." }
                ?? "9router skips one model on this account for a short while."
        case .paused:
            "9router stopped routing to this account after an error\(errorCode.map { " (HTTP \($0))" } ?? ""). Its plan quota is unaffected. Test the connection in the 9router dashboard to resume it."
        case .noBalance: "The upstream account has no credit left."
        case .authError: "The upstream account rejected 9router's credentials. Reconnect it in the 9router dashboard."
        }
    }

    /// The higher of the two windows, or nil when the account reports no plan quota.
    var tightestPercent: Double? {
        switch (sessionPercent, weeklyPercent) {
        case let (s?, w?): max(s, w)
        case let (s?, nil): s
        case let (nil, w?): w
        case (nil, nil): nil
        }
    }

    /// Tightest window first; accounts without a quota after, by 30-day cost.
    static func ordered(_ accounts: [GatewayAccount]) -> [GatewayAccount] {
        accounts.sorted { lhs, rhs in
            switch (lhs.tightestPercent, rhs.tightestPercent) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.cost30dUSD != rhs.cost30dUSD { return lhs.cost30dUSD > rhs.cost30dUSD }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// "4 active · 1 paused" for the card row. The worst-represented state names the count.
    static func summary(_ accounts: [GatewayAccount]) -> String {
        let base = "\(accounts.count) active"
        let problems = accounts.filter(\.status.isProblem)
        guard !problems.isEmpty else { return base }
        let kinds = Set(problems.map(\.status))
        let word = kinds.count == 1 ? kinds.first!.label.lowercased() : "need attention"
        return "\(base) · \(problems.count) \(word)"
    }
}
