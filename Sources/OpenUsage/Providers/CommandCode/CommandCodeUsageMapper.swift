import Foundation

/// Maps Command Code's billing API into the card's rows, the way the CLI's `/usage` view reads them:
/// - `5-hour` / `Weekly`: dollars used against each rolling window's cap (`credits.windowLimits`).
/// - `Monthly`: the plan's monthly credits used this billing period. The cap is the plan's allocation
///   (same table as the CLI); for an unknown plan it's rebuilt from used + remaining.
/// - `Extra credits`: purchased + free credits left (never throttled by the windows).
/// - `Requests`: requests this billing period.
/// Today and Yesterday are billed cost and tokens from `usage/summary?since=` (see
/// `CommandCodeHistorySource`); the API can't look before the current billing period.
enum CommandCodeUsageMapper {
    static let fiveHourPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
    private static let usableStatuses: Set<String> = ["active", "trialing", "past_due"]

    /// Plan id prefix → (name, monthly credits in USD). Mirrors the CLI bundle's tables; matched by the
    /// longest prefix so versioned ids (`individual-pro-v1`) resolve.
    static let plans: [String: (name: String, monthlyCredits: Double)] = [
        "individual-go": ("Go", 10),
        "individual-go-v1": ("Go", 10),
        "individual-goat": ("GOAT", 70),
        "individual-pro": ("Pro", 30),
        "individual-pro-v1": ("Pro", 80),
        "individual-provider": ("Provider", 15),
        "individual-max": ("Max", 150),
        "individual-ultra": ("Ultra", 300),
        "teams-pro": ("Teams Pro", 40)
    ]

    struct Subscription: Equatable, Sendable {
        var planID: String
        var periodStart: Date
        var periodEnd: Date

        var plan: (name: String, monthlyCredits: Double)? { CommandCodeUsageMapper.plan(for: planID) }
        var periodDurationMs: Int { Int((periodEnd.timeIntervalSince(periodStart) * 1000).rounded()) }
    }

    struct Summary: Equatable, Sendable {
        var requests: Int
        var costUSD: Double
        var tokens: Int
    }

    static func plan(for planID: String) -> (name: String, monthlyCredits: Double)? {
        let normalized = planID.lowercased().replacingOccurrences(of: "_", with: "-")
        let key = plans.keys.sorted { $0.count > $1.count }.first { normalized.hasPrefix($0) }
        return key.flatMap { plans[$0] }
    }

    /// `whoami.org.id`, or nil for a personal account.
    static func organizationID(_ body: Data) -> String? {
        guard let org = ProviderParse.jsonObject(body)?["org"] as? [String: Any],
              let id = (org["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    /// The live subscription, or nil when there is none (pay-as-you-go) or it isn't usable.
    static func subscription(_ body: Data) -> Subscription? {
        guard let data = ProviderParse.jsonObject(body)?["data"] as? [String: Any],
              let status = (data["status"] as? String)?.lowercased(), usableStatuses.contains(status),
              let planID = data["planId"] as? String, !planID.isEmpty,
              let start = (data["currentPeriodStart"] as? String).flatMap(OpenUsageISO8601.date(from:)),
              let end = (data["currentPeriodEnd"] as? String).flatMap(OpenUsageISO8601.date(from:)),
              end > start else { return nil }
        return Subscription(planID: planID, periodStart: start, periodEnd: end)
    }

    static func summary(_ body: Data) -> Summary? {
        guard let root = ProviderParse.jsonObject(body),
              let count = ProviderParse.number(root["totalCount"]) else { return nil }
        return Summary(
            requests: max(0, Int(count)),
            costUSD: max(0, ProviderParse.number(root["totalCost"]) ?? 0),
            tokens: max(0, Int(ProviderParse.number(root["totalTokens"]) ?? 0))
        )
    }

    /// 5-hour, Weekly, Monthly, Extra credits, and Requests from `billing/credits`, the subscription
    /// (for Monthly and the plan name), and the period's request count. Throws `invalidResponse` when the
    /// body is not a credits payload.
    static func map(credits body: Data, subscription: Subscription?, requests: Int?) throws -> ProviderUsage {
        guard let root = ProviderParse.jsonObject(body),
              let credits = root["credits"] as? [String: Any] else { throw ProviderError.invalidResponse }
        var lines: [MetricLine] = []

        let windows = root["windowLimits"] as? [String: Any]
        if (windows?["limited"] as? Bool) != false {
            for (key, label, period) in [("fiveHour", "5-hour", fiveHourPeriodMs), ("weekly", "Weekly", weeklyPeriodMs)] {
                guard let window = windows?[key] as? [String: Any],
                      let cap = ProviderParse.number(window["cap"]), cap > 0,
                      let used = ProviderParse.number(window["used"]) else { continue }
                lines.append(.progress(label: label, used: max(0, used), limit: cap, format: .dollars,
                                       resetsAt: date(window["resetAt"]), periodDurationMs: period))
            }
        }

        let monthlyLeft = max(0, ProviderParse.number(credits["monthlyCredits"]) ?? 0)
        if let subscription {
            let allocation = subscription.plan?.monthlyCredits ?? 0
            let limit = max(allocation, monthlyLeft)
            if limit > 0 {
                lines.append(.progress(label: "Monthly", used: limit - monthlyLeft, limit: limit, format: .dollars,
                                       resetsAt: subscription.periodEnd,
                                       periodDurationMs: subscription.periodDurationMs))
            }
        }

        let extra = max(0, ProviderParse.number(credits["purchasedCredits"]) ?? 0)
            + max(0, ProviderParse.number(credits["freeCredits"]) ?? 0)
        lines.append(.values(label: "Extra credits", values: [MetricValue(number: extra, kind: .dollars)]))
        if let requests {
            lines.append(.values(label: "Requests", values: [MetricValue(number: Double(requests), kind: .count, label: "requests")]))
        }
        return ProviderUsage(plan: subscription?.plan?.name, lines: lines)
    }

    /// `resetAt` arrives as epoch milliseconds; accept seconds or an ISO string too.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) { return date }
        guard let number = ProviderParse.number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }
}
