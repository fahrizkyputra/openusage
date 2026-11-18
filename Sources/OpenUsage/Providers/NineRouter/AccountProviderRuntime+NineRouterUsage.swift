import Foundation

extension AccountProviderRuntime {
    /// 9router Kitchen's read, for the summary card and for each connection card. The host comes from the
    /// build, so a build without one is refused before any request leaves. Every Kitchen card of a pass shares
    /// one `/v1/accounts` answer; the summary card also reads `/v1/daily` for the spend rows.
    func refreshNineRouterKitchen(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        guard let host = kitchenHost else { throw ProviderError.unavailable(NineRouterKitchenHost.notConfigured) }
        let client = NineRouterUsageClient(http: http, baseURL: host)
        let connections = try await kitchenReads.connections(now: now()) {
            let response = try await client.accounts(apiKey: apiKey)
            try ProviderError.requireSuccess(response, kind: .ninerouterKitchen)
            guard let list = NineRouterUsageMapper.connections(response.body) else { throw ProviderError.invalidResponse }
            return list
        }
        if let id = account.upstream, let connection = connections.first(where: { $0.id == id }) {
            return NineRouterUsageMapper.connectionUsage(connection)
        }
        guard account.upstream == nil else { throw ProviderError.unavailable("This connection is no longer on the server.") }
        var usage = ProviderUsage(
            plan: nil,
            lines: NineRouterUsageMapper.summaryLines(connections)
                + [.badge(label: "Accounts", text: NineRouterUsageMapper.summary(connections))],
            lineTitles: NineRouterUsageMapper.summaryTitles(connections))
        usage.history = await refreshHistory(using: NineRouterHistorySource(client: client, apiKey: apiKey))
        return usage
    }
}
