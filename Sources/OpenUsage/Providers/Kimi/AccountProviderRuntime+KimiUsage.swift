import Foundation

extension AccountProviderRuntime {
    /// Kimi's Session and Weekly quota. The usage read carries the meters, so a refused key stops there. The
    /// plan name comes from `/me`, once an hour, and a failed lookup keeps the meters and the last plan.
    func refreshKimi(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        let client = KimiUsageClient(http: http)
        let usages = try await client.usages(apiKey: apiKey)
        try ProviderError.requireSuccess(usages, kind: .kimi)
        if planBodyRead.isDue(at: now()) {
            planBodyRead.record(successBody(try? await client.me(apiKey: apiKey)), at: now())
        }
        return try KimiUsageMapper.map(body: usages.body, meBody: planBodyRead.value)
    }
}
