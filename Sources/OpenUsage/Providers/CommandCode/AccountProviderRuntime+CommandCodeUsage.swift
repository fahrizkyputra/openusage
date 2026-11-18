import Foundation

extension AccountProviderRuntime {
    /// Command Code's usage read. The client, mapper, and meters arrive with the next change; until then a
    /// signed-in account reports that the read is not built rather than showing numbers it never read.
    func refreshCommandCode(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey = credential else { throw ProviderError.invalidResponse }
        throw ProviderError.unavailable("Command Code usage is not available in this build yet.")
    }
}
