import XCTest
@testable import OpenUsage

/// The Kimi provider kind: how it signs in, what its card links to, and that saved accounts keep their raw value.
@MainActor
final class KimiKindTests: XCTestCase {
    func testKimiSignsInWithAnAPIKey() throws {
        let methods = ProviderKind.kimi.authMethods
        XCTAssertEqual(methods.count, 1)
        guard case .apiKey(let keyPage)? = methods.first else { return XCTFail("expected an API key sign-in") }
        XCTAssertEqual(keyPage.scheme, "https")
        XCTAssertEqual(keyPage.host, "www.kimi.com")
    }

    func testKimiNamesAndLinksUseTheStandardLabels() {
        XCTAssertEqual(ProviderKind.kimi.displayName, "Kimi")
        XCTAssertEqual(ProviderKind.kimi.links.map(\.label), ["Usage Dashboard"])
        XCTAssertTrue(ProviderKind.kimi.links.allSatisfy { $0.url.scheme == "https" })
    }

    func testKimiRawValueIsStableForSavedAccounts() {
        XCTAssertEqual(ProviderKind.kimi.rawValue, "kimi")
        XCTAssertEqual(ProviderKind(rawValue: "kimi"), .kimi)
    }

    func testKimiUsesTheSharedAPIKeyLogin() {
        let login = ProviderLoginCatalog.login(for: .kimi, method: .apiKey(keyPage: URL(string: "https://www.kimi.com")!),
                                               organization: "", domain: GitHubDomain(saved: nil))
        XCTAssertTrue(login is APIKeyLogin)
    }
}
