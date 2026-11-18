import XCTest
@testable import OpenUsage

private let importAccounts = #"{"accounts":[{"id":"c1","name":"A","provider":"claude","sessionPercent":10,"weeklyPercent":5,"status":"ok"}]}"#
private let importCredits = #"{"credits":{"monthlyCredits":5},"windowLimits":{"limited":false}}"#
private let importUsages = #"{"usage":{"limit":"100","used":"40"}}"#

/// The team API keys an earlier team build saved in OpenUsage's own config folder, imported once. Same contract
/// as the upstream import of the OpenRouter and Z.ai keys: never read another tool's files, one check per key,
/// a provider the user turned off stays off, and a removed account does not come back.
@MainActor
final class TeamKeyImportTests: XCTestCase {
    private let kitchen = URL(string: "https://kitchen.example.com")!

    private func makeHome(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = home.appending(path: ".config/openusage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        for (name, text) in files { try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8) }
        return home
    }

    private func makeStore() -> (AccountStore, InMemoryCredentialVault) {
        let vault = InMemoryCredentialVault()
        return (AccountStore(defaults: isolatedDefaults(), vault: vault), vault)
    }

    nonisolated private static func accepting(_ request: HTTPRequest) -> HTTPResponse {
        switch request.url.host {
        case "kitchen.example.com": .json(importAccounts)
        case "api.kimi.com": .json(importUsages)
        default: .json(importCredits)
        }
    }

    private func run(
        _ store: AccountStore, home: URL, defaults: UserDefaults? = nil, http: RoutingHTTPClient? = nil, host: URL? = nil
    ) async -> RoutingHTTPClient {
        let client = http ?? RoutingHTTPClient { Self.accepting($0) }
        await TeamKeyImport.importOnce(into: store, defaults: defaults ?? isolatedDefaults(), home: home, http: client,
                                       kitchenHost: host ?? kitchen)
        return client
    }

    func testImportsEachTeamKeyAsAnAccountAndLeavesTheFilesAsTheyWere() async throws {
        let home = try makeHome(["9router-kitchen.json": #"{"apiKey":"sk-k"}"#, "commandcode.json": #"{"apiKey":"user_c"}"#,
                                 "kimi.json": #"{"apiKey":"sk-kimi"}"#])
        let (store, vault) = makeStore()

        _ = await run(store, home: home)

        XCTAssertEqual(store.accounts.map(\.kind), [.ninerouterKitchen, .commandcode, .kimi])
        XCTAssertEqual(try store.accounts.map { try vault.load($0.id) }, [.apiKey("sk-k"), .apiKey("user_c"), .apiKey("sk-kimi")])
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".config/openusage/commandcode.json"), encoding: .utf8),
                       #"{"apiKey":"user_c"}"#, "the file stays, so a downgrade finds it as it left it")
    }

    func testRunsOnceAndAKeyIsCheckedOnce() async throws {
        let home = try makeHome(["commandcode.json": #"{"apiKey":"user_c"}"#])
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()

        let first = await run(store, home: home, defaults: defaults)
        let second = await run(store, home: home, defaults: defaults)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(first.requests.filter { $0.url.host == "api.commandcode.ai" }.count > 0, true)
        XCTAssertTrue(second.requests.isEmpty, "a later launch reads no key and sends no check")
    }

    func testAMissingOrBrokenFileIsLeftOutWithoutAnError() async throws {
        let home = try makeHome(["commandcode.json": "{ not json", "kimi.json": #"{"apiKey":"   "}"#])
        let (store, _) = makeStore()

        let http = await run(store, home: home)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(http.requests.isEmpty, "nothing readable, nothing sent")
    }

    func testAPlainTextKeyFileIsAccepted() async throws {
        let home = try makeHome(["kimi.json": "sk-kimi-plain\n"])
        let (store, vault) = makeStore()

        _ = await run(store, home: home)

        XCTAssertEqual(try store.accounts.map { try vault.load($0.id) }, [.apiKey("sk-kimi-plain")])
    }

    func testAProviderThatAlreadyHasAnAccountIsSkipped() async throws {
        let home = try makeHome(["kimi.json": #"{"apiKey":"sk-old"}"#])
        let (store, vault) = makeStore()
        let existing = store.add(kind: .kimi, label: "Work", credential: .apiKey("sk-new"))

        let http = await run(store, home: home)

        XCTAssertEqual(store.accounts.map(\.id), [existing.id])
        XCTAssertEqual(try vault.load(existing.id), .apiKey("sk-new"), "a key the user already added is never overwritten")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAKeyTheServerRejectsIsSkippedAndCheckedOnlyOnce() async throws {
        let home = try makeHome(["commandcode.json": #"{"apiKey":"user_revoked"}"#])
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        let rejecting = RoutingHTTPClient { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }

        _ = await run(store, home: home, defaults: defaults, http: rejecting)
        let again = await run(store, home: home, defaults: defaults)

        XCTAssertTrue(store.accounts.isEmpty, "a rejected key is not turned into an account")
        XCTAssertTrue(again.requests.isEmpty, "and is not offered to the server again")
    }

    func testACheckThatCouldNotReachTheServerIsTriedAgainOnTheNextLaunch() async throws {
        let home = try makeHome(["kimi.json": #"{"apiKey":"sk-kimi"}"#])
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        let down = RoutingHTTPClient { _ in .json("{}", status: 503) }

        _ = await run(store, home: home, defaults: defaults, http: down)
        XCTAssertTrue(store.accounts.isEmpty)
        _ = await run(store, home: home, defaults: defaults)

        XCTAssertEqual(store.accounts.map(\.kind), [.kimi], "a server outage is not a verdict on the key")
    }

    func testARemovedImportedAccountDoesNotComeBack() async throws {
        let home = try makeHome(["kimi.json": #"{"apiKey":"sk-kimi"}"#])
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        _ = await run(store, home: home, defaults: defaults)
        store.remove(try XCTUnwrap(store.accounts.first).id)

        let http = await run(store, home: home, defaults: defaults)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAProviderTheUserTurnedOffStaysOff() async throws {
        let home = try makeHome(["kimi.json": #"{"apiKey":"sk-kimi"}"#, "commandcode.json": #"{"apiKey":"user_c"}"#])
        let (store, _) = makeStore()
        let defaults = isolatedDefaults()
        defaults.set(["claude@aaaa1111", "commandcode"], forKey: "openusage.enabledProviders.v1")

        _ = await run(store, home: home, defaults: defaults)

        XCTAssertEqual(store.accounts.map(\.kind), [.commandcode])
    }

    func testABuildWithoutAKitchenHostImportsNoKitchenKey() async throws {
        let home = try makeHome(["9router-kitchen.json": #"{"apiKey":"sk-k"}"#])
        let (store, _) = makeStore()
        let http = RoutingHTTPClient { _ in
            XCTFail("no host, no check")
            return .json("{}")
        }

        await TeamKeyImport.importOnce(into: store, defaults: isolatedDefaults(), home: home, http: http, kitchenHost: nil)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testTheImportReadsNothingFromAnotherToolsFolder() async throws {
        let home = try makeHome([:])
        let other = home.appending(path: ".commandcode")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try #"{"apiKey":"user_cli"}"#.write(to: other.appending(path: "auth.json"), atomically: true, encoding: .utf8)
        let (store, _) = makeStore()

        let http = await run(store, home: home)

        XCTAssertTrue(store.accounts.isEmpty, "a CLI login of another tool is never discovered")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testTheKitchenKeyThatIsImportedAlsoSyncsItsConnections() async throws {
        let home = try makeHome(["9router-kitchen.json": #"{"apiKey":"sk-k"}"#])
        let (store, _) = makeStore()

        _ = await run(store, home: home)

        XCTAssertEqual(store.accounts.map(\.upstream), [nil, "c1"], "the Kitchen account and its one connection")
    }
}
