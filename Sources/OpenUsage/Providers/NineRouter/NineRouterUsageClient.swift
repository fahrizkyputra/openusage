import Foundation

/// Calls kitchen-usage-proxy, the read-only service at `/openusage` on the Kitchen host. It takes a 9router
/// API key as a Bearer token and never a local CLI token: 9router's own usage routes need admin credentials,
/// which a team member does not have, so the proxy serves a filtered copy.
struct NineRouterUsageClient: Sendable {
    static let proxyPath = "/openusage"

    var http: any HTTPClient
    var baseURL: URL

    /// Every active connection with its windows, 30-day cost, and routing status.
    func accounts(apiKey: String) async throws -> HTTPResponse {
        try await get("/v1/accounts", query: [], apiKey: apiKey)
    }

    /// Thirty server-local days of cost and tokens, plus the top models.
    func daily(apiKey: String) async throws -> HTTPResponse {
        try await get("/v1/daily", query: [URLQueryItem(name: "days", value: "30")], apiKey: apiKey)
    }

    private func get(_ path: String, query: [URLQueryItem], apiKey: String) async throws -> HTTPResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidResponse
        }
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + Self.proxyPath + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderError.invalidResponse }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
            timeout: 15
        ))
    }
}
