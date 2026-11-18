import Foundation

/// Read-only calls to the API the Command Code CLI's `/usage` view reads (`https://api.commandcode.ai/alpha/…`).
/// The host is fixed: this build never reads the environment, so there is no override.
struct CommandCodeUsageClient: Sendable {
    static let baseURL = "https://api.commandcode.ai"

    var http: any HTTPClient

    /// Who the key belongs to; `org.id` scopes the billing calls for an organization seat.
    func whoami(apiKey: String) async throws -> HTTPResponse {
        try await get("/alpha/whoami", query: ["limits": "1"], apiKey: apiKey)
    }

    /// Remaining monthly / purchased / free credits plus the 5-hour and weekly windows.
    func credits(apiKey: String, orgID: String?) async throws -> HTTPResponse {
        try await get("/alpha/billing/credits", query: ["orgId": orgID], apiKey: apiKey)
    }

    /// Plan id, status, and the current billing period.
    func subscription(apiKey: String, orgID: String?) async throws -> HTTPResponse {
        try await get("/alpha/billing/subscriptions", query: ["orgId": orgID], apiKey: apiKey)
    }

    /// Requests, tokens, and billed cost since `since` (clamped by the server to the current billing period).
    func summary(apiKey: String, orgID: String?, since: Date?) async throws -> HTTPResponse {
        try await get("/alpha/usage/summary",
                      query: ["orgId": orgID, "since": since.map(OpenUsageISO8601.string(from:))],
                      apiKey: apiKey)
    }

    private func get(_ path: String, query: [String: String?], apiKey: String) async throws -> HTTPResponse {
        guard var components = URLComponents(string: Self.baseURL + path) else {
            throw ProviderError.invalidResponse
        }
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            .sorted { $0.name < $1.name }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw ProviderError.invalidResponse }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}
