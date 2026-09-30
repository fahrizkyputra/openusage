import CryptoKit
import Foundation

/// Where a 9router server lives and how to authenticate against its dashboard API.
struct NineRouterAuth: Hashable, Sendable {
    enum Credential: Hashable, Sendable {
        /// The `x-9r-cli-token` 9router's own CLI derives from local files (local server only).
        case cliToken(String)
        /// A 9router API key, sent as a Bearer token to kitchen-usage-proxy.
        case apiKey(String)
    }

    /// Base URL of the 9router server, e.g. `http://127.0.0.1:20128`.
    var baseURL: URL
    var credential: Credential

    init(baseURL: URL, cliToken: String) {
        self.init(baseURL: baseURL, credential: .cliToken(cliToken))
    }

    init(baseURL: URL, credential: Credential) {
        self.baseURL = baseURL
        self.credential = credential
    }

    /// Request headers carrying the credential.
    var headers: [String: String] {
        switch credential {
        case .cliToken(let token): [NineRouterUsageClient.tokenHeader: token]
        case .apiKey(let key): ["Authorization": "Bearer \(key)"]
        }
    }
}

enum NineRouterAuthError: Error, LocalizedError, Equatable {
    /// `machine-id` or `auth/cli-secret` is missing — 9router was never started on this machine.
    case notInstalled
    /// The files exist but could not be read.
    case unreadable
    /// The server rejected the derived CLI token (secret rotated, or a different data dir).
    case invalidToken
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "9router not found. Start it once with `9router` so it creates ~/.9router."
        case .unreadable:
            return "Couldn't read 9router's local credentials in ~/.9router."
        case .invalidToken:
            return "9router rejected the local CLI token. Restart 9router and try again."
        case .invalidBaseURL:
            return "NINEROUTER_URL is not a valid URL."
        }
    }
}

/// Derives the same `x-9r-cli-token` 9router's CLI sends to its own server, so OpenUsage can read the
/// dashboard's usage API without a login. 9router computes it as
/// `sha256(machineId + "9r-cli-auth" + cliSecret).hex.prefix(16)`, where both inputs are files the
/// server writes into its data dir (`~/.9router/machine-id` and `~/.9router/auth/cli-secret`, mode 0600).
/// Nothing leaves the machine: the token only unlocks the loopback server that wrote those files.
struct NineRouterAuthStore: Sendable {
    static let defaultDataDirectory = "~/.9router"
    static let defaultBaseURL = "http://127.0.0.1:20128"
    /// Overrides for a non-default 9router install.
    static let dataDirectoryEnvironmentName = "NINEROUTER_DATA_DIR"
    static let baseURLEnvironmentName = "NINEROUTER_URL"
    static let tokenSalt = "9r-cli-auth"

    private let files: TextFileAccessing
    private let environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    var dataDirectory: String {
        let override = environment.value(for: Self.dataDirectoryEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty else { return Self.defaultDataDirectory }
        return override.hasSuffix("/") ? String(override.dropLast()) : override
    }

    var machineIDPath: String { dataDirectory + "/machine-id" }
    var cliSecretPath: String { dataDirectory + "/auth/cli-secret" }

    /// Local-only probe shared with `hasLocalCredentials()`: both token inputs are present.
    func hasCredentialFiles() -> Bool {
        files.exists(machineIDPath) && files.exists(cliSecretPath)
    }

    func load() throws -> NineRouterAuth {
        let machineID: String?
        let secret: String?
        do {
            machineID = try files.readTextIfPresent(machineIDPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
            secret = try files.readTextIfPresent(cliSecretPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AppLog.error(LogTag.auth("9router"), "reading 9router credentials failed: \(error.localizedDescription)")
            throw NineRouterAuthError.unreadable
        }
        guard let machineID, !machineID.isEmpty, let secret, !secret.isEmpty else {
            throw NineRouterAuthError.notInstalled
        }
        return NineRouterAuth(baseURL: try baseURL(), cliToken: Self.cliToken(machineID: machineID, secret: secret))
    }

    func baseURL() throws -> URL {
        let raw = environment.value(for: Self.baseURLEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (raw?.isEmpty == false ? raw! : Self.defaultBaseURL).trimmingTrailingSlashes
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw NineRouterAuthError.invalidBaseURL
        }
        return url
    }

    static func cliToken(machineID: String, secret: String) -> String {
        let digest = SHA256.hash(data: Data((machineID + tokenSalt + secret).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
