import Foundation

/// Today, Yesterday, and 30 days from `/v1/daily`. The server keys its days in its own calendar (UTC), so the
/// source declares that calendar and `UsageHistory` looks days up in it: this Mac, seven hours ahead, never
/// mistakes one server day for another. The cost is what 9router reports, not an estimate made here.
struct NineRouterHistorySource: UsageHistorySource {
    var client: NineRouterUsageClient
    var apiKey: String

    var calendar: Calendar { .utc }
    var rereadInterval: TimeInterval? { 3600 }

    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?) {
        let tag = LogTag.plugin("ninerouter")
        let response: HTTPResponse
        do {
            response = try await client.daily(apiKey: apiKey)
        } catch {
            AppLog.warn(tag, "usage history: request failed")
            return ([:], nil)
        }
        guard (200..<300).contains(response.statusCode) else {
            if case .rateLimited(let retryAfter) = ProviderError.failed(response) { return ([:], retryAfter ?? RefreshSetting.interval) }
            AppLog.warn(tag, "usage history: HTTP \(response.statusCode)")
            return ([:], nil)
        }
        guard let reported = Self.days(response.body, calendar: calendar) else {
            AppLog.warn(tag, "usage history: invalid response")
            return ([:], nil)
        }
        // Inside the window the server answered, a day it names nothing for is quiet, not unread.
        let quiet = UsageDay(totals: UsageTotals(values: [.spend: 0, .tokens: 0]))
        let covered = reported.keys.min().map { oldest in days.filter { $0 >= oldest } } ?? []
        var result = Dictionary(uniqueKeysWithValues: covered.map { ($0, reported[$0] ?? quiet) })
        for (day, value) in reported where days.contains(day) { result[day] = value }
        return (result, nil)
    }

    /// Every day keyed by its server day start, or nil when any date is not a `YYYY-MM-DD` day, so a body is
    /// never partly used.
    static func days(_ body: Data, calendar: Calendar) -> [Date: UsageDay]? {
        guard let root = ProviderParse.jsonObject(body), let rows = root["days"] as? [[String: Any]] else { return nil }
        var days: [Date: UsageDay] = [:]
        for row in rows {
            guard let text = row["date"] as? String,
                  text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let day = Self.formatter(calendar).date(from: text) else { return nil }
            let totals = UsageTotals(values: [
                .spend: max(0, ProviderParse.number(row["costUSD"]) ?? 0),
                .tokens: max(0, ProviderParse.number(row["tokens"]) ?? 0)
            ])
            days[calendar.startOfDay(for: day)] = UsageDay(totals: totals)
        }
        return days
    }

    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
