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
    let now: @Sendable () -> Date

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "kimi.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
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
            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
        } catch let error as KimiUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: KimiUsageError.connectionFailed)
        }
    }
}

extension KimiProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
