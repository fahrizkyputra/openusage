import Foundation

/// Calls the local 9router server's dashboard API (the same routes its web dashboard and CLI use).
/// Every route is authenticated with the locally derived `x-9r-cli-token` header.
struct NineRouterUsageClient: Sendable {
    /// Periods `/api/usage/stats` accepts: `today`, `24h`, `7d`, `30d`, `60d`, `all`.
    enum Period: String, Sendable, CaseIterable {
        case today
        case sevenDays = "7d"
        case thirtyDays = "30d"
    }

    static let statsPath = "/api/usage/stats"
    static let providersPath = "/api/providers"
    static let connectionUsagePath = "/api/usage/"
    static let tokenHeader = "x-9r-cli-token"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Aggregate requests / tokens / cost for one period across every connection.
    func fetchStats(_ period: Period, auth: NineRouterAuth) async throws -> HTTPResponse {
        try await get(Self.statsPath, query: [URLQueryItem(name: "period", value: period.rawValue)], auth: auth)
    }

    /// Every configured upstream connection (Claude accounts, API keys, …) with its active flag.
    func fetchConnections(auth: NineRouterAuth) async throws -> HTTPResponse {
        try await get(Self.providersPath, auth: auth)
    }

    /// Live plan quotas for one connection, as 9router fetches them from the upstream provider.
    func fetchConnectionUsage(connectionID: String, auth: NineRouterAuth) async throws -> HTTPResponse {
        let escaped = connectionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? connectionID
        return try await get(Self.connectionUsagePath + escaped, auth: auth)
    }

    private func get(_ path: String, query: [URLQueryItem] = [], auth: NineRouterAuth) async throws -> HTTPResponse {
        guard var components = URLComponents(url: auth.baseURL, resolvingAgainstBaseURL: false) else {
            throw NineRouterUsageError.invalidResponse
        }
        components.path = components.path.trimmingTrailingSlashes + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw NineRouterUsageError.invalidResponse }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                Self.tokenHeader: auth.cliToken,
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum NineRouterUsageError: Error, LocalizedError, Equatable {
    case notRunning
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Couldn't reach 9router. Is the server running (`9router`)?"
        case .invalidResponse:
            return "9router usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "9router request failed (HTTP \(status))."
        }
    }
}
