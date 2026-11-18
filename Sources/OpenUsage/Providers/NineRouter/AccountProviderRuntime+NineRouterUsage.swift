import Foundation

extension AccountProviderRuntime {
    /// 9router Kitchen's read. The host comes from the build, so a build without one is refused before any
    /// request leaves. The usage client and mapper arrive with the next change.
    func refreshNineRouterKitchen(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey = credential else { throw ProviderError.invalidResponse }
        guard kitchenHost != nil else { throw ProviderError.unavailable(NineRouterKitchenHost.notConfigured) }
        throw ProviderError.unavailable("9router Kitchen usage is not available in this build yet.")
    }
}
