import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi",
        icon: .providerMark("kimi"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://www.kimi.com/code/console"),
            ProviderLink(label: "Usage", url: "https://www.kimi.com/code")
        ]
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let openCodeUsageScanner: OpenCodeKimiUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        openCodeUsageScanner: OpenCodeKimiUsageScanner = OpenCodeKimiUsageScanner(),
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.openCodeUsageScanner = openCodeUsageScanner
        self.pricing = pricing
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "kimi.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your pi logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: KimiAuthError.missingKey)
        }

        do {
            let response = try await usageClient.fetchUsages(apiKey: auth.apiKey)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: KimiAuthError.invalidKey)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: KimiUsageError.requestFailed(response.statusCode))
            }
            // Best-effort plan name: a failed /me call must not blank the quota meters.
            var meBody: Data?
            if let me = try? await usageClient.fetchMe(apiKey: auth.apiKey), (200..<300).contains(me.statusCode) {
                meBody = me.body
            }
            let mapped = try KimiUsageMapper.map(body: response.body, meBody: meBody)
            return await snapshotWithLocalUsage(mapped: mapped)
        } catch let error as KimiUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: KimiUsageError.connectionFailed)
        }
    }
    /// Fold Kimi usage that happened inside pi and OpenCode into the card: Usage Trend plus the
    /// Today / Yesterday / Last 30 Days spend tiles, scanned from local harness logs and priced through
    /// the shared engine (pi carries authoritative per-message costs; OpenCode BYO-key rows record $0
    /// and get priced). No local logs → no local rows.
    private func snapshotWithLocalUsage(mapped: (plan: String?, lines: [MetricLine])) async -> ProviderSnapshot {
        var lines = mapped.lines
        var usageHistory: ProviderUsageHistory?
        let pricing = await pricing()
        async let pi = PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
        async let openCode = openCodeUsageScanner.scan(now: now(), pricing: pricing)
        let (piScan, openCodeScan) = await (pi, openCode)
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([piScan, openCodeScan]) {
            var sources: [String] = []
            if piScan != nil { sources.append("pi") }
            if openCodeScan != nil { sources.append("OpenCode") }
            let note = "From your \(sources.joined(separator: " and ")) logs (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: now(), note: note)
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }
}

extension KimiProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
