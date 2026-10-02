import Foundation

/// Command Code (commandcode.ai): the plan's rolling 5-hour and weekly windows, monthly credits, extra
/// credits, requests, and billed Today / Yesterday spend, read from the same API the CLI's `/usage`
/// view uses. The key comes from the app, `COMMAND_CODE_API_KEY`, or the CLI's login.
@MainActor
final class CommandCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "commandcode",
        displayName: "Command Code",
        icon: .providerMark("commandcode"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://commandcode.ai/studio"),
            ProviderLink(label: "Status", url: "https://status.commandcode.ai")
        ]
    )

    static let billedNote = "Billed by Command Code"

    let authStore: CommandCodeAuthStore
    let usageClient: CommandCodeUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CommandCodeAuthStore = CommandCodeAuthStore(),
        usageClient: CommandCodeUsageClient = CommandCodeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        let spend = WidgetDescriptor.spendTiles(provider: provider, valueTooltipNote: Self.billedNote)
            .filter { $0.metricLabel != "Last 30 Days" }
        return [
            .boundedDollars(id: "commandcode.fiveHour", provider: provider, title: "5-hour",
                            metricLabel: "5-hour", limit: 14)
                .exportingLimit("fiveHour", unit: "usd"),
            .boundedDollars(id: "commandcode.weekly", provider: provider, title: "Weekly",
                            metricLabel: "Weekly", limit: 35)
                .exportingLimit("weekly", unit: "usd"),
            .boundedDollars(id: "commandcode.monthly", provider: provider, title: "Monthly",
                            metricLabel: "Monthly", limit: 70)
                .exportingLimit("monthly", unit: "usd"),
            .dollarBalance(id: "commandcode.extra", provider: provider, title: "Extra credits",
                           metricLabel: "Extra credits", valueWord: "left"),
            .values(id: "commandcode.requests", provider: provider, title: "Requests",
                    metricLabel: "Requests", selection: .kind(.count))
        ] + spend
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let apiKey = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.missingKey)
        }
        let now = now()

        let client = usageClient
        let whoami = await Self.load { try await client.fetchWhoami(apiKey: apiKey) }
        if case .authFailure = whoami {
            return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.invalidKey)
        }
        let orgID = whoami.body.flatMap(CommandCodeUsageMapper.organizationID)

        async let creditsCall = Self.load { try await client.fetchCredits(apiKey: apiKey, orgID: orgID) }
        async let subscriptionCall = Self.load { try await client.fetchSubscription(apiKey: apiKey, orgID: orgID) }
        let (credits, subscriptionResult) = await (creditsCall, subscriptionCall)
        if credits.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.invalidKey)
        }
        let subscription = subscriptionResult.body.flatMap(CommandCodeUsageMapper.subscription)

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let periodStart = subscription?.periodStart
        async let periodCall = Self.load { try await client.fetchSummary(apiKey: apiKey, orgID: orgID, since: periodStart) }
        async let todayCall = Self.load { try await client.fetchSummary(apiKey: apiKey, orgID: orgID, since: startOfToday) }
        async let yesterdayCall = Self.load { try await client.fetchSummary(apiKey: apiKey, orgID: orgID, since: startOfYesterday) }
        let (period, today, yesterday) = await (periodCall, todayCall, yesterdayCall)

        var lines = credits.body.flatMap { CommandCodeUsageMapper.creditLines($0, subscription: subscription) } ?? []
        if let summary = period.body.flatMap(CommandCodeUsageMapper.summary) {
            lines.append(CommandCodeUsageMapper.requestsLine(summary))
        }
        lines += CommandCodeUsageMapper.spendLines(
            sinceToday: today.body.flatMap(CommandCodeUsageMapper.summary),
            sinceYesterday: yesterday.body.flatMap(CommandCodeUsageMapper.summary),
            periodStart: subscription?.periodStart,
            now: now,
            calendar: calendar
        )

        guard !lines.isEmpty else {
            let error = credits.failure ?? whoami.failure ?? CommandCodeUsageError.invalidResponse
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        return ProviderSnapshot.make(provider: provider, plan: subscription?.plan?.name, lines: lines, refreshedAt: now)
    }

    /// Run one call and classify it: the body on 2xx, an auth failure on 401/403, else a typed failure.
    /// Nonisolated so the independent calls run concurrently.
    nonisolated private static func load(_ call: @Sendable () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

extension CommandCodeProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.loadAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
    var apiKeyPlaceholder: String { "user_… (Command Code API key)" }
}

private enum EndpointResult: Sendable {
    case success(Data)
    case authFailure
    case failed(CommandCodeUsageError)

    var body: Data? {
        if case .success(let data) = self { return data }
        return nil
    }

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }

    var failure: CommandCodeUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
