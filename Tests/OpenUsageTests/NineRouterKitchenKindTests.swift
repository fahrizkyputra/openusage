import XCTest
@testable import OpenUsage

/// The 9router Kitchen kind: an API key sign-in whose host comes from the build, never from the source.
@MainActor
final class NineRouterKitchenKindTests: XCTestCase {
    private func writePlist(_ values: [String: String]) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("OpenUsage.app/Contents")
        let helper = contents.appendingPathComponent("Helpers/openusage")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data())
        var plist: [String: Any] = ["CFBundleIdentifier": "com.example.test", "CFBundlePackageType": "APPL"]
        for (key, value) in values { plist[key] = value }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return (root, helper)
    }

    func testKitchenSignsInWithAnAPIKeyAndUsesTheSharedLogin() {
        guard case .apiKey? = ProviderKind.ninerouterKitchen.authMethods.first else { return XCTFail("an API key sign-in") }
        XCTAssertEqual(ProviderKind.ninerouterKitchen.authMethods.count, 1)
        XCTAssertEqual(ProviderKind.ninerouterKitchen.displayName, "9router Kitchen")
        XCTAssertEqual(ProviderKind.ninerouterKitchen.rawValue, "ninerouterKitchen")
        let login = ProviderLoginCatalog.login(for: .ninerouterKitchen, method: .apiKey(keyPage: URL(string: "https://example.com")!),
                                               organization: "", domain: GitHubDomain(saved: nil))
        XCTAssertTrue(login is APIKeyLogin)
    }

    func testNoHostInSourceMeansTheKindLinksNowhere() {
        // The source carries no host: links come from the build, so the bare kind has none to show.
        XCTAssertEqual(ProviderKind.ninerouterKitchen.links, [])
    }

    func testTheHostComesFromTheBuildAndTheEnvironmentIsNotRead() throws {
        let (root, helper) = try writePlist([NineRouterKitchenHost.infoPlistKey: "https://kitchen.example.com/"])
        defer { try? FileManager.default.removeItem(at: root) }

        // The test runner's own Bundle.main has no key, like the CLI helper; the host is found in the .app.
        XCTAssertNil(NineRouterKitchenHost.baseURL(main: .main, executableURL: root.appendingPathComponent("loose-binary")))
        XCTAssertEqual(NineRouterKitchenHost.baseURL(main: .main, executableURL: helper)?.absoluteString,
                       "https://kitchen.example.com", "the trailing slash is dropped")
    }

    func testABuildWithoutAHostRefusesTheKindInsteadOfSendingAnything() async throws {
        let account = Account(kind: .ninerouterKitchen, label: "Kitchen")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("k"), for: account.id)
        let http = RoutingHTTPClient { _ in
            XCTFail("no host, no request")
            return .json("{}")
        }

        let result = await AccountProviderRuntime(account: account, vault: vault, http: http, kitchenHost: nil).refresh()

        guard case .failure(let failure) = result else { return XCTFail("a build without a host cannot read usage") }
        XCTAssertEqual(failure.message, "9router Kitchen isn't configured in this build.")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAnInvalidHostIsRejectedRatherThanUsed() {
        for bad in ["not a url", "ftp://kitchen.example.com", "kitchen.example.com", "https://"] {
            XCTAssertNil(NineRouterKitchenHost.validated(bad), bad)
        }
        XCTAssertEqual(NineRouterKitchenHost.validated(" http://127.0.0.1:20180 ")?.absoluteString, "http://127.0.0.1:20180")
    }

    func testAnAccountCarriesNoUpstreamUnlessItIsAConnection() {
        XCTAssertNil(Account(kind: .claude, label: "Work").upstream)
        let connection = Account(kind: .ninerouterKitchen, label: "personal 5 max", upstream: "conn-1")
        XCTAssertEqual(connection.upstream, "conn-1")
        XCTAssertNil(connection.domain, "the connection id never rides in the field the UI prints as a domain")
    }

    func testAnOlderAccountRecordWithoutTheFieldStillDecodes() throws {
        let record = #"{"id":"6F4C1B2E-0000-4000-8000-000000000001","kind":"claude","label":"Work","addedAt":0}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(record.utf8))
        XCTAssertNil(account.upstream)
    }
}
