import Foundation

struct KimiAuth: Hashable, Sendable {
    var apiKey: String
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Kimi API key. Set KIMI_API_KEY or add it to ~/.config/openusage/kimi.json."
        case .invalidKey:
            return "Kimi API key invalid. Check your Kimi for Coding key."
        case .saveFailed:
            return "Couldn't save the Kimi API key."
        case .deleteFailed:
            return "Couldn't remove the saved Kimi API key."
        }
    }
}

/// Reads a [Kimi for Coding](https://www.kimi.com) API key the user has already placed on the machine.
/// Like OpenRouter, Kimi has no companion CLI/app that stashes a credential in a known spot, so the key
/// comes from an environment variable or a small config file (see `LoginShellEnvironment` for why the
/// env var still works in a packaged app).
struct KimiAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/kimi.json"
    ]
    static let environmentNames = ["KIMI_API_KEY"]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { KimiAuthError($0) }
        )
    }

    func loadAPIKey() -> KimiAuth? { store.loadKey().map(KimiAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
