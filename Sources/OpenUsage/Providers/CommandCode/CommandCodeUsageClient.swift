import Foundation

/// Read-only calls to the API the Command Code CLI's `/usage` view reads (`https://api.commandcode.ai/alpha/…`).
/// `COMMAND_CODE_API_BASE_URL` overrides the host, as it does for the CLI.
struct CommandCodeUsageClient: Sendable {
    static let defaultBaseURL = "https://api.commandcode.ai"
    static let baseURLEnvironmentName = "COMMAND_CODE_API_BASE_URL"

    var http: any HTTPClient
    var baseURL: String

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.http = http
        let override = environment.value(for: Self.baseURLEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = (override?.isEmpty == false ? override! : Self.defaultBaseURL).trimmingTrailingSlashes
    }

    /// Who the key belongs to; `org.id` scopes the billing calls for an organization seat.
    func fetchWhoami(apiKey: String) async throws -> HTTPResponse {
        try await get("/alpha/whoami", query: ["limits": "1"], apiKey: apiKey)
    }

    /// Remaining monthly / purchased / free credits plus the 5-hour and weekly windows.
    func fetchCredits(apiKey: String, orgID: String?) async throws -> HTTPResponse {
        try await get("/alpha/billing/credits", query: ["orgId": orgID], apiKey: apiKey)
    }

    /// Plan id, status, and the current billing period.
    func fetchSubscription(apiKey: String, orgID: String?) async throws -> HTTPResponse {
        try await get("/alpha/billing/subscriptions", query: ["orgId": orgID], apiKey: apiKey)
    }

    /// Requests, tokens, and billed cost since `since` (clamped by the server to the current billing period).
    func fetchSummary(apiKey: String, orgID: String?, since: Date?) async throws -> HTTPResponse {
        try await get("/alpha/usage/summary",
                      query: ["orgId": orgID, "since": since.map(OpenUsageISO8601.string(from:))],
                      apiKey: apiKey)
    }

    private func get(_ path: String, query: [String: String?], apiKey: String) async throws -> HTTPResponse {
        guard var components = URLComponents(string: baseURL + path) else {
            throw CommandCodeUsageError.invalidResponse
        }
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            .sorted { $0.name < $1.name }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw CommandCodeUsageError.invalidResponse }
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

enum CommandCodeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach Command Code. Check your connection."
        case .invalidResponse:
            return "Command Code usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "Command Code request failed (HTTP \(status))."
        }
    }
}
