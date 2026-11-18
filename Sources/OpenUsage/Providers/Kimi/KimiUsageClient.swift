import Foundation

struct KimiUsageClient: Sendable {
    /// Kimi for Coding's usage endpoint: weekly quota plus the rolling rate-limit windows.
    static let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    /// Account profile — carries the retail plan name (`user_level_name`, e.g. "Vivace").
    static let meURL = URL(string: "https://api.kimi.com/coding/v1/me")!

    var http: any HTTPClient

    func usages(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.usagesURL, apiKey: apiKey)
    }

    /// The account profile — best-effort, used only to surface the retail plan name. A failure here
    /// must not blank out the quota meters, so the provider treats it as optional.
    func me(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.meURL, apiKey: apiKey)
    }

    private func get(_ url: URL, apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
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
