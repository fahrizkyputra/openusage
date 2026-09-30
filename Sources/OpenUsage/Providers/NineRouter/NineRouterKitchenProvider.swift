import Foundation

/// 9router Kitchen — a remote 9router server whose host is configured per build (see
/// `NineRouterKitchenAuthStore`), tracked as its own card next to the local 9router gateway. Same metrics as `NineRouterProvider`, read through
/// kitchen-usage-proxy (`/openusage/v1/...`) with an ordinary 9router API key as a Bearer token, so the
/// team never needs the dashboard (admin) password.
@MainActor
final class NineRouterKitchenProvider: ProviderRuntime {
    static let providerID = "9router-kitchen"
    static let displayName = "9router Kitchen"

    let provider: Provider
    let authStore: NineRouterKitchenAuthStore
    let usageClient: NineRouterUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: NineRouterKitchenAuthStore = NineRouterKitchenAuthStore(),
        usageClient: NineRouterUsageClient = NineRouterUsageClient(
            routes: .proxy(basePath: NineRouterKitchenAuthStore.defaultProxyPath)
        ),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        // No links when the host isn't configured: a relative "/dashboard/..." would be a dead button.
        let links = (try? authStore.baseURL().absoluteString).map { base in [
            ProviderLink(label: "Usage", url: base + "/dashboard/usage"),
            ProviderLink(label: "Dashboard", url: base + "/dashboard/quota")
        ] } ?? []
        provider = Provider(
            id: Self.providerID,
            displayName: Self.displayName,
            icon: .providerMark("9router"),
            links: links
        )
    }

    /// Same card as the local gateway. History is `.accountWide`: every Mac already reads the shared
    /// server's total, so iCloud sync must not add Macs together.
    var widgetDescriptors: [WidgetDescriptor] {
        NineRouterProvider.widgetDescriptors(for: provider, historyScope: .accountWide)
    }

    /// On in any build that carries a Kitchen host (team builds): the API key can only be entered after
    /// install, so the card starts on and shows "No 9router Kitchen API key" until it's added. Builds
    /// without a host keep it off.
    var enablesWithoutCredentials: Bool { authStore.configuredBaseURL() != nil }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: a configured Kitchen host and a saved or exported API key.
        await loadOffMainActor { [authStore] in
            authStore.configuredBaseURL() != nil && authStore.loadAPIKey() != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        let baseURL: URL
        do {
            baseURL = try authStore.baseURL()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let key = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: NineRouterKitchenAuthError.missingKey)
        }

        let fetcher = NineRouterUsageFetcher(
            usageClient: usageClient,
            logTag: LogTag.plugin(provider.id),
            unreachableError: .unreachable(Self.displayName)
        )
        let now = now()
        switch await fetcher.fetch(auth: NineRouterAuth(baseURL: baseURL, credential: .apiKey(key)), now: now) {
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
            return ProviderSnapshot.error(provider: provider, error: NineRouterKitchenAuthError.invalidKey)
        case .failed(.requestFailed(429)):
            return ProviderSnapshot.error(provider: provider, error: NineRouterKitchenAuthError.rateLimited)
        case .failed(.requestFailed(502)):
            // The proxy answers 502 when it can't read 9router with its own admin token.
            return ProviderSnapshot.error(provider: provider, error: NineRouterKitchenAuthError.proxyMisconfigured)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}

extension NineRouterKitchenProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    var apiKeyPlaceholder: String { "sk-… (9router Kitchen API key)" }
    func currentAPIKey() -> String? { authStore.loadAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
