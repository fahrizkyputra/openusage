import Foundation

/// Reads Kimi-for-Coding usage produced inside OpenCode (BYO-key provider `kimi-for-coding`) and
/// returns it in the same normalized shape as the pi scanner, so the Kimi card can fold it into its
/// Usage Trend and spend tiles. OpenCode records BYO-key rows with `cost = 0`, so tokens are priced
/// through the shared engine — OpenCode-hosted Kimi models (`providerID = opencode/opencode-go`,
/// `kimi-k2.5-free` etc.) are deliberately excluded: that usage bills to the OpenCode card, not Kimi.
struct OpenCodeKimiUsageScanner: Sendable {
    private let sqlite: SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    /// Best-effort supplementary scan: failures are logged loudly but never hide Kimi's live quota
    /// meters or pi history. Returns nil when there is no OpenCode database at all.
    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> LogUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "Kimi usage database discovery failed: \(error.localizedDescription)")
            return nil
        }
        guard !paths.isEmpty else { return nil }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(since.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        var failures: [String: String] = [:]
        for path in paths {
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                failures[path] = error.localizedDescription
            }
        }
        let newlyFailing = await readFailureReporter.update(
            checkedPaths: Set(paths), failingPaths: Set(failures.keys)
        )
        for path in newlyFailing.sorted() {
            AppLog.warn(
                LogTag.plugin("opencode"),
                "Kimi usage query failed for \(path): \(failures[path] ?? "unknown error")"
            )
        }
        guard failures.count < paths.count else { return nil }

        var accumulator = DailyUsageAccumulator()
        for row in Self.deduplicated(rows) where row.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: row.timestamp)
            guard let rawModel = row.model.nilIfEmpty else { continue }
            let model = Self.pricingModelAlias(for: rawModel) ?? rawModel
            if let carried = row.cost, carried > 0 {
                accumulator.add(day: day, tokens: row.reportedTotalTokens, cost: carried, model: rawModel)
            } else if let estimated = pricing.estimatedCostDollars(model: model, tokens: row.tokens) {
                accumulator.add(day: day, tokens: row.reportedTotalTokens, cost: estimated, model: rawModel)
            } else if row.reportedTotalTokens > 0 {
                accumulator.addUnknownModel(day: day, model: rawModel)
            }
        }
        return accumulator.build()
    }

    /// OpenCode logs the bare wire model id (`k3`, `kimi-for-coding`); the pricing catalog keys on
    /// catalog slugs. Unknown ids pass through untouched so the pricing engine's own alias rules still
    /// get their say.
    static func pricingModelAlias(for model: String) -> String? {
        switch model.lowercased() {
        case "k3", "k3-256k": return "kimi-k3"
        case "kimi-for-coding": return "kimi-k2.7-code"
        // ponytail: highspeed priced at standard K2.7-code rates; true highspeed multiplier (~3x) is
        // unpublished — upgrade when models.dev carries a kimi-for-coding-highspeed rate.
        case "kimi-for-coding-highspeed": return "kimi-k2.7-code"
        default: return nil
        }
    }

    struct Row: Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var model: String
        var cost: Double?
        var tokens: TokenBreakdown
        var reportedTotalTokens: Int
    }

    /// Decodes `[completedAt, cost, total, model, input, cacheRead, cacheWrite, output, reasoning, id]`
    /// — same column order as the Codex twin's query.
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        return payload.compactMap { element in
            guard let values = element as? [Any], values.count >= 10,
                  let milliseconds = ProviderParse.number(values[0])
            else { return nil }
            let input = clampedTokens(values[4])
            let cacheRead = clampedTokens(values[5])
            let cacheWrite = clampedTokens(values[6])
            let output = clampedTokens(values[7])
            let reasoning = clampedTokens(values[8])
            let tokens = TokenBreakdown(
                input: input,
                cacheWrite5m: cacheWrite,
                cacheRead: cacheRead,
                output: output + reasoning
            )
            return Row(
                id: (values[9] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
                model: ((values[3] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                cost: ProviderParse.number(values[1]),
                tokens: tokens,
                reportedTotalTokens: tokens.totalTokens > 0 ? tokens.totalTokens : clampedTokens(values[2])
            )
        }
    }

    /// Same cross-database copy safety as the Codex twin: stable message IDs, keep the newest/fullest.
    static func deduplicated(_ rows: [Row]) -> [Row] {
        var withoutID: [Row] = []
        var byID: [String: Row] = [:]
        for row in rows {
            guard let id = row.id else {
                withoutID.append(row)
                continue
            }
            guard let existing = byID[id] else {
                byID[id] = row
                continue
            }
            if row.timestamp > existing.timestamp ||
                (row.timestamp == existing.timestamp && row.reportedTotalTokens > existing.reportedTotalTokens) {
                byID[id] = row
            }
        }
        return withoutID + byID.values
    }

    private static func clampedTokens(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }

    /// Only BYO-key Kimi providers — never `opencode`/`opencode-go`, whose hosted kimi-* models bill
    /// to the OpenCode subscription. Unlike the Codex twin no OAuth gate applies: a custom provider
    /// with an API key is the only way these provider IDs exist.
    static func dataSQL(cutoffMs: Int) -> String {
        let creationCutoffMs = cutoffMs - 7 * 86_400_000
        return """
        SELECT json_group_array(json_array(
                 COALESCE(json_extract(data,'$.time.completed'),time_created),
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 json_extract(data,'$.modelID'),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 id))
        FROM message
        WHERE time_created >= \(creationCutoffMs)
          AND json_valid(data)
          AND COALESCE(json_extract(data,'$.time.completed'),time_created) >= \(cutoffMs)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN ('kimi-for-coding','kimi','moonshot','moonshotai')
          AND (json_type(data,'$.time.completed') IN ('integer','real')
               OR json_type(data,'$.finish') = 'text');
        """
    }
}
