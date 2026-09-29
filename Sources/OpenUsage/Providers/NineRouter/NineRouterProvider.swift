import Foundation

/// 9router — a local AI gateway (https://github.com/decolua/9router) that rotates requests across
/// several upstream accounts. OpenUsage reads the gateway's own dashboard API on loopback: spend per
/// period from `/api/usage/stats`, and the tightest Session / Weekly plan window across every active
/// upstream connection.
@MainActor
final class NineRouterProvider: ProviderRuntime {
    let provider = Provider(
        id: "9router",
        displayName: "9router",
        icon: .providerMark("9router"),
        links: [
            ProviderLink(label: "Usage", url: "http://localhost:20128/dashboard/usage"),
            ProviderLink(label: "Dashboard", url: "http://localhost:20128/dashboard/quota")
        ]
    )

    let authStore: NineRouterAuthStore
    let usageClient: NineRouterUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: NineRouterAuthStore = NineRouterAuthStore(),
        usageClient: NineRouterUsageClient = NineRouterUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    /// Spend rows in display order, paired with the stats period that backs each one.
    static let spendRows: [(label: String, period: NineRouterUsageClient.Period)] = [
        ("Today", .today),
        ("Last 7 Days", .sevenDays),
        ("Last 30 Days", .thirtyDays)
    ]

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "9router.session", provider: provider, title: "Session", metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "9router.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .combined(id: "9router.today", provider: provider, title: "Today", isUsagePeriod: true),
            .combined(id: "9router.week", provider: provider, title: "Last 7 Days", isUsagePeriod: true),
            .combined(id: "9router.month", provider: provider, title: "Last 30 Days", isUsagePeriod: true)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: the two files 9router writes the first time it starts.
        await loadOffMainActor { [authStore] in authStore.hasCredentialFiles() }
    }

    func refresh() async -> ProviderSnapshot {
        let auth: NineRouterAuth
        do {
            auth = try await loadOffMainActor { [authStore] in try authStore.load() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        // Stats are required: they prove the server is up and the token works. The first call decides
        // the error the user sees when nothing comes back.
        var lines: [MetricLine] = []
        for row in Self.spendRows {
            switch await load({ try await usageClient.fetchStats(row.period, auth: auth) }) {
            case .success(let body):
                guard let line = NineRouterUsageMapper.spendLine(label: row.label, body: body) else {
                    return ProviderSnapshot.error(provider: provider, error: NineRouterUsageError.invalidResponse)
                }
                lines.append(line)
            case .authFailure:
                return ProviderSnapshot.error(provider: provider, error: NineRouterAuthError.invalidToken)
            case .failed(let error):
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        // Quotas are best-effort: a connection without plan data (plain API keys, custom endpoints)
        // or a failing upstream must not blank out the spend rows.
        let quota = await tightestQuotas(auth: auth)
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: quota.lines + lines,
            refreshedAt: now(),
            lineSources: quota.sources.isEmpty ? nil : quota.sources
        )
    }

    private func tightestQuotas(auth: NineRouterAuth) async -> (lines: [MetricLine], sources: [String: String]) {
        guard case .success(let body) = await load({ try await usageClient.fetchConnections(auth: auth) }),
              let connections = NineRouterUsageMapper.activeConnections(body) else {
            AppLog.warn(LogTag.plugin("9router"), "connection list unavailable; skipping quota meters")
            return ([], [:])
        }
        var quotas: [NineRouterUsageMapper.Quota] = []
        for connection in connections {
            guard case .success(let usageBody) = await load({
                try await usageClient.fetchConnectionUsage(connectionID: connection.id, auth: auth)
            }) else {
                AppLog.info(LogTag.plugin("9router"), "quota unavailable for one connection; skipping it")
                continue
            }
            quotas += NineRouterUsageMapper.quotas(usageBody, source: connection.name)
        }
        return NineRouterUsageMapper.tightestQuotas(quotas)
    }

    /// Run one call and classify the outcome: the body on 2xx, an auth failure on 401/403, or a typed
    /// failure for any other status or a transport error (server not running).
    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.notRunning)
        }
    }
}

private enum EndpointResult {
    case success(Data)
    case authFailure
    case failed(NineRouterUsageError)
}
