import XCTest
@testable import OpenUsage

/// The Command Code provider kind: how it signs in, what the account card links to, and that it
/// takes the shared API key path rather than a login of its own.
@MainActor
final class CommandCodeKindTests: XCTestCase {
    func testCommandCodeSignsInWithAnAPIKey() throws {
        let methods = ProviderKind.commandcode.authMethods
        XCTAssertEqual(methods.count, 1)
        guard case .apiKey(let keyPage)? = methods.first else { return XCTFail("expected an API key sign-in") }
        XCTAssertEqual(keyPage.host, "commandcode.ai")
        XCTAssertEqual(keyPage.scheme, "https")
    }

    func testCommandCodeNamesAndLinksUseTheStandardLabels() {
        XCTAssertEqual(ProviderKind.commandcode.displayName, "Command Code")
        XCTAssertEqual(ProviderKind.commandcode.links.map(\.label), ["Status Page", "Usage Dashboard"])
        XCTAssertTrue(ProviderKind.commandcode.links.allSatisfy { $0.url.scheme == "https" })
    }

    func testCommandCodeRawValueIsStableForSavedAccounts() {
        XCTAssertEqual(ProviderKind.commandcode.rawValue, "commandcode")
        XCTAssertEqual(ProviderKind(rawValue: "commandcode"), .commandcode)
    }

    func testCommandCodeUsesTheSharedAPIKeyLogin() {
        let login = ProviderLoginCatalog.login(for: .commandcode, method: .apiKey(keyPage: URL(string: "https://commandcode.ai")!),
                                               organization: "", domain: GitHubDomain(saved: nil))
        XCTAssertTrue(login is APIKeyLogin, "no bespoke login: the key is checked by one usage read")
    }

    func testCommandCodeReportsNoUsageUntilTheMapperIsBuilt() async throws {
        // Registered, so the runtime accepts the kind. The read itself arrives with the usage client (T5).
        let account = Account(kind: .commandcode, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: RoutingHTTPClient { _ in .json("{}") })
        XCTAssertEqual(runtime.provider.kind, .commandcode)
        XCTAssertEqual(runtime.provider.displayName, "Command Code")
    }
}
