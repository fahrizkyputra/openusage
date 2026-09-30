import Foundation

/// 9router's per-day usage, in the one shape both 9router cards read: the local card builds it from
/// the gateway's `/api/usage/chart` + `/api/usage/stats`, the Kitchen card gets it verbatim from
/// kitchen-usage-proxy's `/openusage/v1/daily`. Days are the *server's* calendar days.
struct NineRouterDailyUsage: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        var date: String          // YYYY-MM-DD, server-local
        var costUSD: Double
        var tokens: Int
    }

    struct Model: Equatable, Sendable {
        var model: String
        var costUSD: Double
        var tokens: Int
    }

    /// IANA zone the days are keyed in, when the server reports it.
    var timeZone: String?
    /// Oldest first; the last entry is the server's today.
    var days: [Day]
    var todayModels: [Model]
    var last30Models: [Model]

    static let estimateNote = "Priced by 9router at API rates — for subscriptions this is API-equivalent value, not your bill."

    // MARK: - Parsing

    /// kitchen-usage-proxy's `/openusage/v1/daily` body.
    static func parseProxy(_ body: Data) -> NineRouterDailyUsage? {
        guard let root = ProviderParse.jsonObject(body), let rawDays = root["days"] as? [[String: Any]] else { return nil }
        let days = rawDays.compactMap { day -> Day? in
            guard let date = day["date"] as? String, isDayKey(date) else { return nil }
            return Day(date: date,
                       costUSD: max(0, ProviderParse.number(day["costUSD"]) ?? 0),
                       tokens: max(0, Int(ProviderParse.number(day["tokens"]) ?? 0)))
        }
        guard days.count == rawDays.count else { return nil }
        let models = root["models"] as? [String: Any]
        return NineRouterDailyUsage(
            timeZone: root["timeZone"] as? String,
            days: days,
            todayModels: parseModels(models?["today"]),
            last30Models: parseModels(models?["last30"])
        )
    }

    /// The local gateway's `/api/usage/chart?period=30d` points (oldest first, one per server-local day,
    /// labelled without a year) keyed back to ISO dates by position from `now`. The local server shares
    /// this Mac's clock and zone, so `calendar` is the Mac's.
    static func fromLocalChart(
        _ chartBody: Data,
        todayStats: Data?,
        last30Stats: Data?,
        now: Date,
        calendar: Calendar = .current
    ) -> NineRouterDailyUsage? {
        guard let data = try? JSONSerialization.jsonObject(with: chartBody), let points = data as? [[String: Any]],
              !points.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let days = points.enumerated().compactMap { index, point -> Day? in
            guard let day = calendar.date(byAdding: .day, value: -(points.count - 1 - index), to: today) else { return nil }
            return Day(date: DailyUsageAccumulator.dayKey(from: day, calendar: calendar),
                       costUSD: max(0, ProviderParse.number(point["cost"]) ?? 0),
                       tokens: max(0, Int(ProviderParse.number(point["tokens"]) ?? 0)))
        }
        return NineRouterDailyUsage(
            timeZone: calendar.timeZone.identifier,
            days: days,
            todayModels: todayStats.map(statsModels) ?? [],
            last30Models: last30Stats.map(statsModels) ?? []
        )
    }

    /// Top 5 models by cost from a `/api/usage/stats` body's `byModel`.
    static func statsModels(_ body: Data) -> [Model] {
        guard let byModel = ProviderParse.jsonObject(body)?["byModel"] as? [String: Any] else { return [] }
        let models = byModel.values.compactMap { value -> Model? in
            guard let entry = value as? [String: Any] else { return nil }
            let name = (entry["rawModel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let tokens = Int((ProviderParse.number(entry["promptTokens"]) ?? 0) + (ProviderParse.number(entry["completionTokens"]) ?? 0))
            return Model(model: name, costUSD: max(0, ProviderParse.number(entry["cost"]) ?? 0), tokens: max(0, tokens))
        }
        return ranked(models)
    }

    private static func parseModels(_ value: Any?) -> [Model] {
        guard let list = value as? [[String: Any]] else { return [] }
        return ranked(list.compactMap { entry in
            guard let name = entry["model"] as? String, !name.isEmpty else { return nil }
            return Model(model: name,
                         costUSD: max(0, ProviderParse.number(entry["costUSD"]) ?? 0),
                         tokens: max(0, Int(ProviderParse.number(entry["tokens"]) ?? 0)))
        })
    }

    private static func ranked(_ models: [Model]) -> [Model] {
        Array(models
            .filter { $0.costUSD > 0 || $0.tokens > 0 }
            .sorted { $0.costUSD != $1.costUSD ? $0.costUSD > $1.costUSD : ($0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.model < $1.model) }
            .prefix(5))
    }

    private static func isDayKey(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    // MARK: - Rendering

    /// The normalized history the shared spend tiles, Usage Trend, cache, and iCloud sync consume.
    /// Only today carries a model split (9router ranks models per period, not per day).
    var history: ProviderUsageHistory {
        let series = DailyUsageSeries(daily: days.map {
            DailyUsageEntry(date: $0.date, totalTokens: $0.tokens, costUSD: $0.costUSD)
        })
        let todayKey = days.last?.date
        let modelUsage = todayKey.flatMap { key -> ModelUsageSeries? in
            todayModels.isEmpty ? nil : ModelUsageSeries(daily: [DailyModelUsageEntry(
                date: key,
                models: todayModels.map { ModelUsageEntry(model: $0.model, totalTokens: $0.tokens, costUSD: $0.costUSD) }
            )])
        }
        return ProviderUsageHistory(series: series, modelUsage: modelUsage)
    }

    /// Source note for the rows: the estimate caveat, plus the server's zone when it isn't this Mac's.
    func sourceNote(macTimeZone: TimeZone = .current) -> String {
        guard let timeZone, timeZone != macTimeZone.identifier,
              let zone = TimeZone(identifier: timeZone),
              zone.secondsFromGMT() != macTimeZone.secondsFromGMT() else { return Self.estimateNote }
        return Self.estimateNote + " Days follow the server's time zone (\(timeZone))."
    }

    /// The instant the shared mapper should treat as "now", so its Today / Yesterday / 30-day window
    /// land on the *server's* days even when the server's zone differs from this Mac's: noon, in this
    /// Mac's calendar, of the server's last reported day.
    func anchorDate(now: Date, calendar: Calendar = .current) -> Date {
        guard let key = days.last?.date else { return now }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let anchor = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return now }
        return anchor
    }

    /// Append Today / Yesterday / Last 30 Days and Usage Trend, then attach the 30-day model ranking
    /// to the Last 30 Days tile (the shared mapper only knows per-day splits).
    func appendLines(to lines: inout [MetricLine], now: Date, note: String) {
        let history = self.history
        let anchor = anchorDate(now: now)
        SpendTileMapper.appendTokenUsage(
            history.series, to: &lines, now: anchor, estimated: true,
            modelUsage: history.modelUsage, modelSourceNote: note
        )
        SpendTileMapper.appendUsageTrend(history.series, to: &lines, now: anchor, note: note)
        Self.attach(last30Models, toLineLabeled: "Last 30 Days", in: &lines, note: note)
    }

    static func attach(_ models: [Model], toLineLabeled label: String, in lines: inout [MetricLine], note: String) {
        guard !models.isEmpty, let index = lines.firstIndex(where: { $0.label == label }),
              case .values(let lineLabel, let values, let color, let expiries, let unknown, _) = lines[index] else { return }
        let tokens = Int(values.first { $0.kind == .count }?.number ?? 0)
        let cost = values.first { $0.kind == .dollars }?.number
        lines[index] = .values(
            label: lineLabel, values: values, colorHex: color, expiriesAt: expiries, unknownModels: unknown,
            modelBreakdown: ModelUsageBreakdown(
                totalTokens: tokens,
                totalCostUSD: cost,
                models: models.map { ModelUsageEntry(model: $0.model, totalTokens: $0.tokens, costUSD: $0.costUSD) },
                sourceNote: note
            )
        )
    }
}
