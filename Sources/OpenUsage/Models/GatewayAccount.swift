import Foundation

/// One upstream account behind a gateway card (a 9router connection): its plan windows, 30-day cost,
/// and health. Rendered by the card's "Accounts" row and its hover list.
struct GatewayAccount: Hashable, Sendable, Codable {
    /// Metric-line label of the card row that lists the accounts.
    static let lineLabel = "Accounts"

    enum Status: String, Hashable, Sendable, Codable {
        case ok
        case rateLimited = "rate_limited"
        case noBalance = "no_balance"
        case authError = "auth_error"
        case error

        var label: String {
            switch self {
            case .ok: "OK"
            case .rateLimited: "Rate limited"
            case .noBalance: "No balance"
            case .authError: "Auth error"
            case .error: "Error"
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

    /// "4 active · 1 limited" for the card row.
    static func summary(_ accounts: [GatewayAccount]) -> String {
        let problems = accounts.filter(\.status.isProblem).count
        let base = "\(accounts.count) active"
        return problems > 0 ? "\(base) · \(problems) limited" : base
    }
}
