import Foundation

/// 9router — a local AI gateway (https://github.com/decolua/9router) that rotates requests across
/// several upstream accounts. OpenUsage reads the gateway's own dashboard API on loopback: per-day
/// spend from `/api/usage/chart` (the shared Today / Yesterday / Last 30 Days tiles, Usage Trend, and
/// Total Spend), model rankings from `/api/usage/stats`, and the tightest Session / Weekly plan window
/// across every active upstream connection.
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

    var widgetDescriptors: [WidgetDescriptor] {
        Self.widgetDescriptors(for: provider, historyScope: .machineLocal)
    }

    /// The shared 9router card: Session, Weekly, Usage Trend, then the shared spend tiles (which feed
    /// Total Spend). `historyScope` is `.machineLocal` for a per-Mac gateway (iCloud sync sums Macs)
    /// and `.accountWide` for a shared server (every Mac already sees the server's total).
    static func widgetDescriptors(for provider: Provider, historyScope: UsageHistoryDescriptor.Scope) -> [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly", metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .gatewayAccounts(id: "\(provider.id).accounts", provider: provider),
            .usageTrend(provider: provider)
                .exportingHistory(scope: historyScope, estimatedCost: true, sourceNote: NineRouterDailyUsage.estimateNote)
        ] + WidgetDescriptor.spendTiles(provider: provider, valueTooltipNote: NineRouterDailyUsage.estimateNote)
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

        let fetcher = NineRouterUsageFetcher(
            usageClient: usageClient,
            logTag: LogTag.plugin(provider.id),
            unreachableError: .notRunning
        )
        let now = now()
        switch await fetcher.fetch(auth: auth, now: now) {
        case .success(let lines, let sources, let history, let accounts):
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: lines,
                refreshedAt: now,
                usageHistory: history,
                lineSources: sources.isEmpty ? nil : sources,
                accounts: accounts.isEmpty ? nil : accounts
            )
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: NineRouterAuthError.invalidToken)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
