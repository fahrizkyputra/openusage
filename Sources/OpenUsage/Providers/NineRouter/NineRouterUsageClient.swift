import Foundation

/// Calls a 9router usage API. Two route layouts share one client:
/// - `.native`: the 9router server's own dashboard routes (local card, `x-9r-cli-token`).
/// - `.proxy`: kitchen-usage-proxy's read-only routes (Kitchen card, Bearer API key), which return the
///   same JSON shapes filtered down to the fields OpenUsage reads.
struct NineRouterUsageClient: Sendable {
    /// Periods OpenUsage asks 9router's stats and chart routes for.
    enum Period: String, Sendable, CaseIterable {
        case today
        case thirtyDays = "30d"
    }

    enum Routes: Sendable, Equatable {
        case native
        /// kitchen-usage-proxy mounted at `basePath` (default `/openusage`).
        case proxy(basePath: String)

        var statsPath: String {
            switch self {
            case .native: "/api/usage/stats"
            case .proxy(let base): base + "/v1/stats"
            }
        }

        var connectionsPath: String {
            switch self {
            case .native: "/api/providers"
            case .proxy(let base): base + "/v1/connections"
            }
        }

        /// kitchen-usage-proxy's merged account list (proxy only; the native layout builds it locally).
        var accountsPath: String? {
            switch self {
            case .native: nil
            case .proxy(let base): base + "/v1/accounts"
            }
        }

        /// Per-day spend: 9router's chart (native) or the proxy's pre-keyed `/v1/daily`.
        var dailyPath: String {
            switch self {
            case .native: "/api/usage/chart"
            case .proxy(let base): base + "/v1/daily"
            }
        }

        func connectionUsagePath(_ escapedID: String) -> String {
            switch self {
            case .native: "/api/usage/" + escapedID
            case .proxy(let base): base + "/v1/connections/" + escapedID + "/usage"
            }
        }
    }

    static let statsPath = Routes.native.statsPath
    static let providersPath = Routes.native.connectionsPath
    static let chartPath = Routes.native.dailyPath
    static let connectionUsagePath = "/api/usage/"
    static let tokenHeader = "x-9r-cli-token"

    var http: any HTTPClient
    var routes: Routes

    init(http: any HTTPClient = URLSessionHTTPClient(), routes: Routes = .native) {
        self.http = http
        self.routes = routes
    }

    /// Aggregate requests / tokens / cost for one period across every connection.
    func fetchStats(_ period: Period, auth: NineRouterAuth) async throws -> HTTPResponse {
        try await get(routes.statsPath, query: [URLQueryItem(name: "period", value: period.rawValue)], auth: auth)
    }

    /// Per-day spend for the last 30 days. Native: `/api/usage/chart?period=30d` (points oldest first,
    /// labelled without a year). Proxy: `/v1/daily?days=30` (ISO dates, server zone, top models).
    func fetchDaily(auth: NineRouterAuth) async throws -> HTTPResponse {
        switch routes {
        case .native: try await get(routes.dailyPath, query: [URLQueryItem(name: "period", value: Period.thirtyDays.rawValue)], auth: auth)
        case .proxy: try await get(routes.dailyPath, query: [URLQueryItem(name: "days", value: "30")], auth: auth)
        }
    }

    /// Every active account with windows, 30-day cost, and status (proxy layout only).
    func fetchAccounts(auth: NineRouterAuth) async throws -> HTTPResponse {
        guard let path = routes.accountsPath else { throw NineRouterUsageError.invalidResponse }
        return try await get(path, auth: auth)
    }

    /// Every configured upstream connection (Claude accounts, API keys, …) with its active flag.
    func fetchConnections(auth: NineRouterAuth) async throws -> HTTPResponse {
        try await get(routes.connectionsPath, auth: auth)
    }

    /// Live plan quotas for one connection, as 9router fetches them from the upstream provider.
    func fetchConnectionUsage(connectionID: String, auth: NineRouterAuth) async throws -> HTTPResponse {
        // Escape everything but unreserved characters, so an id can never add a path segment.
        let escaped = connectionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) ?? connectionID
        return try await get(routes.connectionUsagePath(escaped), auth: auth)
    }

    private func get(_ path: String, query: [URLQueryItem] = [], auth: NineRouterAuth) async throws -> HTTPResponse {
        var headers = auth.headers
        headers["Accept"] = "application/json"
        return try await http.send(HTTPRequest(
            method: "GET",
            url: try Self.url(auth.baseURL, path: path, query: query),
            headers: headers,
            timeout: 15
        ))
    }

    private static func url(_ baseURL: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NineRouterUsageError.invalidResponse
        }
        components.percentEncodedPath = components.percentEncodedPath.trimmingTrailingSlashes + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw NineRouterUsageError.invalidResponse }
        return url
    }
}

enum NineRouterUsageError: Error, LocalizedError, Equatable {
    /// The local server didn't answer.
    case notRunning
    /// A remote server didn't answer; carries its display name.
    case unreachable(String)
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Couldn't reach 9router. Is the server running (`9router`)?"
        case .unreachable(let name):
            return "Couldn't reach \(name). Check your connection."
        case .invalidResponse:
            return "9router usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "9router request failed (HTTP \(status))."
        }
    }
}
