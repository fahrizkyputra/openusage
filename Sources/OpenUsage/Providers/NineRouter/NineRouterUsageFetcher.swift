import Foundation

/// The fetch-and-map pass shared by every 9router card (the local gateway and remote servers such as
/// 9router Kitchen): per-day spend (the shared spend tiles, Usage Trend, and Total Spend), top models,
/// and the tightest Session / Weekly plan window across active upstream connections. Only how the card
/// authenticates, and which route layout it reads, differ — the caller hands in a client and credential.
struct NineRouterUsageFetcher: Sendable {
    enum Outcome: Sendable {
        case success(lines: [MetricLine], sources: [String: String], history: ProviderUsageHistory,
                     accounts: [GatewayAccount])
        /// The server rejected the credential (401/403) on the required daily-spend call.
        case authFailure
        case failed(NineRouterUsageError)
    }

    let usageClient: NineRouterUsageClient
    let logTag: String
    /// The error to report when the server can't be reached at all.
    let unreachableError: NineRouterUsageError

    func fetch(auth: NineRouterAuth, now: Date) async -> Outcome {
        // Daily spend is required: it proves the server is up and the credential works.
        let daily: NineRouterDailyUsage
        var last30Stats: Data?
        switch await load({ try await usageClient.fetchDaily(auth: auth) }) {
        case .authFailure:
            return .authFailure
        case .failed(let error):
            return .failed(error)
        case .success(let body):
            switch usageClient.routes {
            case .proxy:
                guard let parsed = NineRouterDailyUsage.parseProxy(body) else { return .failed(.invalidResponse) }
                daily = parsed
            case .native:
                // Model rankings are best-effort: the totals still render without them.
                let today = await load({ try await usageClient.fetchStats(.today, auth: auth) }).body
                let last30 = await load({ try await usageClient.fetchStats(.thirtyDays, auth: auth) }).body
                last30Stats = last30
                guard let parsed = NineRouterDailyUsage.fromLocalChart(
                    body, todayStats: today, last30Stats: last30, now: now
                ) else { return .failed(.invalidResponse) }
                daily = parsed
            }
        }

        var lines: [MetricLine] = []
        daily.appendLines(to: &lines, now: now, note: daily.sourceNote())

        // Quotas are best-effort: a connection without plan data (plain API keys, custom endpoints)
        // or a failing upstream must not blank out the spend rows.
        let quota: (lines: [MetricLine], sources: [String: String], accounts: [GatewayAccount])
        switch usageClient.routes {
        case .native: quota = await localQuotas(auth: auth, last30Stats: last30Stats, now: now)
        case .proxy: quota = await proxyQuotas(auth: auth)
        }
        return .success(lines: quota.lines + lines, sources: quota.sources, history: daily.history, accounts: quota.accounts)
    }

    /// The proxy's `/v1/accounts` already carries each account's windows, so the card's tightest
    /// Session / Weekly come from it in one call instead of one call per connection.
    private func proxyQuotas(auth: NineRouterAuth) async
        -> (lines: [MetricLine], sources: [String: String], accounts: [GatewayAccount]) {
        guard case .success(let body) = await load({ try await usageClient.fetchAccounts(auth: auth) }),
              let accounts = NineRouterUsageMapper.proxyAccounts(body) else {
            AppLog.warn(logTag, "account list unavailable; falling back to per-connection quotas")
            let legacy = await tightestQuotas(auth: auth)
            return (legacy.lines, legacy.sources, [])
        }
        let quotas = accounts.flatMap { account -> [NineRouterUsageMapper.Quota] in
            [(NineRouterUsageMapper.Window.session, account.sessionPercent),
             (NineRouterUsageMapper.Window.weekly, account.weeklyPercent)].compactMap { window, percent in
                percent.map { NineRouterUsageMapper.Quota(window: window, percent: $0, resetsAt: nil, source: account.name) }
            }
        }
        // Reset times aren't part of the account list: take them from the per-connection quota of the
        // two winning accounts only.
        let tightest = await withResetTimes(NineRouterUsageMapper.tightestQuotas(quotas), accounts: accounts, auth: auth)
        let lines = tightest.lines + [NineRouterUsageMapper.accountsLine(accounts)].compactMap { $0 }
        return (lines, tightest.sources, accounts)
    }

    /// Fill the Session / Weekly reset times from the connections that won each window.
    private func withResetTimes(
        _ tightest: (lines: [MetricLine], sources: [String: String]),
        accounts: [GatewayAccount],
        auth: NineRouterAuth
    ) async -> (lines: [MetricLine], sources: [String: String]) {
        var resets: [String: Date] = [:]
        for (label, name) in tightest.sources {
            guard let id = accounts.first(where: { $0.name == name })?.id,
                  case .success(let body) = await load({ try await usageClient.fetchConnectionUsage(connectionID: id, auth: auth) })
            else { continue }
            let window: NineRouterUsageMapper.Window = label == "Session" ? .session : .weekly
            if let reset = NineRouterUsageMapper.quotas(body).filter({ $0.window == window }).max(by: { $0.percent < $1.percent })?.resetsAt {
                resets[label] = reset
            }
        }
        let lines = tightest.lines.map { line -> MetricLine in
            guard case .progress(let label, let used, let limit, let format, _, let period, let color) = line,
                  let reset = resets[label] else { return line }
            return .progress(label: label, used: used, limit: limit, format: format, resetsAt: reset,
                             periodDurationMs: period, colorHex: color)
        }
        return (lines, tightest.sources)
    }

    private func localQuotas(auth: NineRouterAuth, last30Stats: Data?, now: Date) async
        -> (lines: [MetricLine], sources: [String: String], accounts: [GatewayAccount]) {
        guard case .success(let body) = await load({ try await usageClient.fetchConnections(auth: auth) }),
              let connections = NineRouterUsageMapper.activeConnections(body) else {
            AppLog.warn(logTag, "connection list unavailable; skipping quota meters")
            return ([], [:], [])
        }
        var quotas: [NineRouterUsageMapper.Quota] = []
        var usageByID: [String: Data] = [:]
        for connection in connections {
            guard case .success(let usageBody) = await load({
                try await usageClient.fetchConnectionUsage(connectionID: connection.id, auth: auth)
            }) else {
                AppLog.info(logTag, "quota unavailable for one connection; skipping it")
                continue
            }
            usageByID[connection.id] = usageBody
            quotas += NineRouterUsageMapper.quotas(usageBody, source: connection.name)
        }
        let tightest = NineRouterUsageMapper.tightestQuotas(quotas)
        let accounts = NineRouterUsageMapper.localAccounts(
            connections: body, usageByID: usageByID, stats30: last30Stats, now: now
        )
        let lines = tightest.lines + [NineRouterUsageMapper.accountsLine(accounts)].compactMap { $0 }
        return (lines, tightest.sources, accounts)
    }

    private func tightestQuotas(auth: NineRouterAuth) async -> (lines: [MetricLine], sources: [String: String]) {
        guard case .success(let body) = await load({ try await usageClient.fetchConnections(auth: auth) }),
              let connections = NineRouterUsageMapper.activeConnections(body) else {
            AppLog.warn(logTag, "connection list unavailable; skipping quota meters")
            return ([], [:])
        }
        var quotas: [NineRouterUsageMapper.Quota] = []
        for connection in connections {
            guard case .success(let usageBody) = await load({
                try await usageClient.fetchConnectionUsage(connectionID: connection.id, auth: auth)
            }) else {
                AppLog.info(logTag, "quota unavailable for one connection; skipping it")
                continue
            }
            quotas += NineRouterUsageMapper.quotas(usageBody, source: connection.name)
        }
        return NineRouterUsageMapper.tightestQuotas(quotas)
    }

    private enum EndpointResult {
        case success(Data)
        case authFailure
        case failed(NineRouterUsageError)

        var body: Data? {
            if case .success(let data) = self { return data }
            return nil
        }
    }

    /// Run one call and classify the outcome: the body on 2xx, an auth failure on 401/403, or a typed
    /// failure for any other status or a transport error (server unreachable).
    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(unreachableError)
        }
    }
}
