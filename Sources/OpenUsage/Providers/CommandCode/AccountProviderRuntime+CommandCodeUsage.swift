import Foundation

extension AccountProviderRuntime {
    /// Command Code's windows, monthly credits, extra credits, and requests. `whoami` comes first because an
    /// organization seat scopes every later call by its org id. The credits read carries the meters, so a
    /// refused key stops here; the subscription (plan and billing period) and the period's request count
    /// are best-effort, because the meters are worth showing without them.
    func refreshCommandCode(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        let client = CommandCodeUsageClient(http: http)

        let whoami = try await client.whoami(apiKey: apiKey)
        try ProviderError.requireSuccess(whoami, kind: .commandcode)
        let orgID = CommandCodeUsageMapper.organizationID(whoami.body)

        async let credits = client.credits(apiKey: apiKey, orgID: orgID)
        async let subscription = client.subscription(apiKey: apiKey, orgID: orgID)
        let (creditsResponse, subscriptionResponse) = try await (credits, subscription)
        try ProviderError.requireSuccess(creditsResponse, kind: .commandcode)

        let plan = successBody(subscriptionResponse).flatMap(CommandCodeUsageMapper.subscription)
        let summary = try? await client.summary(apiKey: apiKey, orgID: orgID, since: plan?.periodStart)
        let requests = summary.flatMap(successBody).flatMap(CommandCodeUsageMapper.summary)?.requests
        var usage = try CommandCodeUsageMapper.map(credits: creditsResponse.body, subscription: plan, requests: requests)
        usage.history = await refreshHistory(using: CommandCodeHistorySource(
            client: client, apiKey: apiKey, orgID: orgID, periodStart: plan?.periodStart))
        return usage
    }
}
