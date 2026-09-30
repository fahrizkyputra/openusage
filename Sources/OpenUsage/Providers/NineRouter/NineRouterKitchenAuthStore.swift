import Foundation

enum NineRouterKitchenAuthError: Error, LocalizedError, Equatable {
    case missingKey
    /// The proxy rejected the key (unknown, inactive, or revoked in the Kitchen dashboard).
    case invalidKey
    /// Too many failed keys from this network, or too many requests for this key.
    case rateLimited
    /// The proxy is up but can't read 9router with its own admin token (server-side misconfiguration).
    case proxyMisconfigured
    /// No Kitchen host in the build (Info.plist) or the environment.
    case notConfigured
    case invalidBaseURL
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
            return "No 9router Kitchen API key. Add it in Customize → 9router Kitchen → API Key."
        case .invalidKey:
            return "9router Kitchen rejected the API key. Check that it is active in the Kitchen dashboard."
        case .rateLimited:
            return "9router Kitchen is rate-limiting requests. Try again in a few minutes."
        case .proxyMisconfigured:
            return "9router Kitchen usage service can't reach 9router. Tell the Kitchen admin."
        case .notConfigured:
            return "9router Kitchen isn't configured in this build. Set NINEROUTER_KITCHEN_URL."
        case .invalidBaseURL:
            return "The 9router Kitchen URL is not a valid http(s) URL."
        case .saveFailed:
            return "Couldn't save the 9router Kitchen API key."
        case .deleteFailed:
            return "Couldn't remove the saved 9router Kitchen API key."
        }
    }
}

/// Reads the 9router API key used for the remote 9router Kitchen card. Kitchen usage is served by
/// kitchen-usage-proxy (mounted at `/openusage` on the Kitchen host), which accepts any active 9router
/// API key, so nobody needs the dashboard (admin) password. Stored like every other user API key
/// (config file, then environment), so the in-app key editor manages it.
///
/// The Kitchen host is not part of the source: a packaged build carries it in its Info.plist
/// (`NineRouterKitchenURL`, written at packaging time), and `NINEROUTER_KITCHEN_URL` overrides it.
struct NineRouterKitchenAuthStore: Sendable {
    static let defaultProxyPath = "/openusage"
    static let baseURLEnvironmentName = "NINEROUTER_KITCHEN_URL"
    static let infoPlistKey = "NineRouterKitchenURL"
    static let configPaths = ["~/.config/openusage/9router-kitchen.json"]
    static let environmentNames = ["NINEROUTER_KITCHEN_API_KEY"]

    private let store: UserAPIKeyStore
    private let environment: EnvironmentReading
    private let bundledBaseURL: String?

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        bundledBaseURL: String? = Bundle.main.object(forInfoDictionaryKey: NineRouterKitchenAuthStore.infoPlistKey) as? String
    ) {
        self.environment = environment
        self.bundledBaseURL = bundledBaseURL
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { NineRouterKitchenAuthError($0) }
        )
    }

    func loadAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    /// The Kitchen host (dashboard links and the proxy both live here): environment first, then the
    /// value baked into this build. Nil when neither is set.
    func configuredBaseURL() -> String? {
        let candidates = [environment.value(for: Self.baseURLEnvironmentName), bundledBaseURL]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }?
            .trimmingTrailingSlashes
    }

    func baseURL() throws -> URL {
        guard let value = configuredBaseURL() else { throw NineRouterKitchenAuthError.notConfigured }
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw NineRouterKitchenAuthError.invalidBaseURL
        }
        return url
    }
}
