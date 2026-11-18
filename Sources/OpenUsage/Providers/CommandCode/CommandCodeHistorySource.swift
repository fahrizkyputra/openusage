import Foundation

/// Today and Yesterday from `usage/summary`, which reports cost and tokens cumulatively since a start
/// instant, never per day. Today is the reading since the start of today; Yesterday is the reading since
/// the start of yesterday minus today's. A day that began before the billing period is left unread, because
/// the API cannot see the part of it before the period and the total would be short.
struct CommandCodeHistorySource: UsageHistorySource {
    var client: CommandCodeUsageClient
    var apiKey: String
    var orgID: String?
    /// Start of the current billing period; nil when the subscription is unknown.
    var periodStart: Date?

    /// Hourly, so history adds two calls an hour per account.
    var rereadInterval: TimeInterval? { 3600 }

    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?) {
        let today = calendar.startOfDay(for: asOf)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return ([:], nil) }
        let wanted = Set(days)
        var result: [Date: UsageDay] = [:]

        guard wanted.contains(today) || wanted.contains(yesterday), covers(today) else { return ([:], nil) }
        let sinceToday = await reading(since: today)
        if let wait = sinceToday.rateLimitedFor { return ([:], wait) }
        guard let todayTotals = sinceToday.totals else { return ([:], nil) }
        if wanted.contains(today) { result[today] = UsageDay(totals: todayTotals) }

        guard wanted.contains(yesterday), covers(yesterday) else { return (result, nil) }
        let sinceYesterday = await reading(since: yesterday)
        if let wait = sinceYesterday.rateLimitedFor { return (result, wait) }
        guard let both = sinceYesterday.totals else { return (result, nil) }
        result[yesterday] = UsageDay(totals: Self.difference(both, todayTotals))
        return (result, nil)
    }

    /// Whether the billing period includes the whole of the day starting at `dayStart`.
    private func covers(_ dayStart: Date) -> Bool {
        periodStart.map { $0 <= dayStart } ?? true
    }

    private func reading(since: Date) async -> (totals: UsageTotals?, rateLimitedFor: TimeInterval?) {
        let tag = LogTag.plugin("commandcode")
        let response: HTTPResponse
        do {
            response = try await client.summary(apiKey: apiKey, orgID: orgID, since: since)
        } catch {
            AppLog.warn(tag, "usage history: request failed")
            return (nil, nil)
        }
        if case .rateLimited(let retryAfter) = ProviderError.failed(response), !(200..<300).contains(response.statusCode) {
            return (nil, retryAfter ?? RefreshSetting.interval)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(tag, "usage history: HTTP \(response.statusCode)")
            return (nil, nil)
        }
        guard let summary = CommandCodeUsageMapper.summary(response.body) else {
            AppLog.warn(tag, "usage history: invalid response")
            return (nil, nil)
        }
        return (UsageTotals(values: [.spend: summary.costUSD, .tokens: Double(summary.tokens)]), nil)
    }

    private static func difference(_ whole: UsageTotals, _ part: UsageTotals) -> UsageTotals {
        var values: [UsageMeasure: Double] = [:]
        for (measure, number) in whole.values {
            values[measure] = max(0, number - (part.values[measure] ?? 0))
        }
        return UsageTotals(values: values)
    }
}
