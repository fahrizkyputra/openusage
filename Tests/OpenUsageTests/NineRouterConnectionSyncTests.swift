import XCTest
@testable import OpenUsage

private let kitchenThree = #"""
{"accounts":[
  {"id":"c1","name":"personal 5 max","provider":"claude","sessionPercent":40,"weeklyPercent":20,"cost30dUSD":12,"status":"ok"},
  {"id":"c2","name":"Account 2","provider":"claude","sessionPercent":10,"weeklyPercent":5,"cost30dUSD":3,"status":"paused","errorCode":429},
  {"id":"c3","name":"Free Model","provider":"openrouter","cost30dUSD":0,"status":"ok"}
]}
"""#

/// Every active connection behind a Kitchen becomes an account of its own, named after the connection, and
/// goes away when the connection does. The Kitchen account holds the one API key all of them read with.
@MainActor
final class NineRouterConnectionSyncTests: XCTestCase {
    private func makeStore() -> (AccountStore, Account) {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let kitchen = store.add(kind: .ninerouterKitchen, label: "Team", credential: .apiKey("sk-team"))
        return (store, kitchen)
    }

    private func connections(_ json: String) throws -> [KitchenConnection] {
        try XCTUnwrap(NineRouterUsageMapper.connections(Data(json.utf8)))
    }

    func testEveryConnectionBecomesAnAccountAfterTheKitchenAccount() throws {
        let (store, kitchen) = makeStore()

        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))

        XCTAssertEqual(store.accounts.map(\.label), ["Team", "personal 5 max", "Account 2", "Free Model"])
        XCTAssertEqual(store.accounts.map(\.upstream), [nil, "c1", "c2", "c3"])
        XCTAssertTrue(store.accounts.dropFirst().allSatisfy { $0.kind == .ninerouterKitchen })
    }

    func testTheSameListAppliedTwiceChangesNothing() throws {
        let (store, kitchen) = makeStore()
        let list = try connections(kitchenThree)
        try store.syncKitchenConnections(of: kitchen.id, to: list)
        let before = store.accounts

        try store.syncKitchenConnections(of: kitchen.id, to: list)

        XCTAssertEqual(store.accounts, before, "ids, order, and names are stable across a re-sync")
    }

    func testANewConnectionIsAddedBelowAndAGoneOneIsRemoved() throws {
        let (store, kitchen) = makeStore()
        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))
        let kept = store.accounts.first { $0.upstream == "c1" }!.id

        let next = #"{"accounts":[{"id":"c1","name":"personal 5 max","provider":"claude","status":"ok"},{"id":"c4","name":"New one","provider":"claude","status":"ok"}]}"#
        try store.syncKitchenConnections(of: kitchen.id, to: connections(next))

        XCTAssertEqual(store.accounts.map(\.upstream), [nil, "c1", "c4"])
        XCTAssertEqual(store.accounts.first { $0.upstream == "c1" }?.id, kept, "a surviving connection keeps its account")
    }

    func testARenamedConnectionKeepsItsAccountAndTakesTheNewName() throws {
        let (store, kitchen) = makeStore()
        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))
        let id = store.accounts.first { $0.upstream == "c2" }!.id

        let renamed = #"{"accounts":[{"id":"c2","name":"Account Two","provider":"claude","status":"ok"}]}"#
        try store.syncKitchenConnections(of: kitchen.id, to: connections(renamed))

        XCTAssertEqual(store.accounts.first { $0.upstream == "c2" }?.id, id)
        XCTAssertEqual(store.accounts.first { $0.upstream == "c2" }?.label, "Account Two")
    }

    func testAnEmptyAnswerRemovesTheConnectionsButNeverTheKitchenAccount() throws {
        let (store, kitchen) = makeStore()
        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))

        try store.syncKitchenConnections(of: kitchen.id, to: [])

        XCTAssertEqual(store.accounts.map(\.id), [kitchen.id], "the account that holds the API key is the user's, not the server's")
    }

    func testAConnectionAccountHasNoKeychainItemOfItsOwn() throws {
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        let kitchen = store.add(kind: .ninerouterKitchen, label: "Team", credential: .apiKey("sk-team"))

        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))

        for child in store.accounts.dropFirst() { XCTAssertNil(try vault.load(child.id), "no copy of the key per connection") }
        XCTAssertEqual(try vault.load(kitchen.id), .apiKey("sk-team"))
    }

    func testRemovingTheKitchenAccountRemovesItsConnectionAccounts() throws {
        let (store, kitchen) = makeStore()
        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))

        store.remove(kitchen.id)

        XCTAssertTrue(store.accounts.isEmpty, "a connection card with no key to read it would only fail")
    }

    func testAnotherKitchenAccountsConnectionsAreLeftAlone() throws {
        let (store, first) = makeStore()
        let second = store.add(kind: .ninerouterKitchen, label: "Second", credential: .apiKey("sk-other"))
        try store.syncKitchenConnections(of: first.id, to: connections(kitchenThree))
        try store.syncKitchenConnections(of: second.id, to: connections(#"{"accounts":[{"id":"z1","name":"Z","provider":"claude","status":"ok"}]}"#))

        try store.syncKitchenConnections(of: first.id, to: [])

        XCTAssertEqual(store.accounts.map(\.label), ["Team", "Second", "Z"], "each Kitchen account owns only its own connections")
    }

    func testAConnectionRuntimeReadsWithTheKitchenAccountsKey() async throws {
        let (store, kitchen) = makeStore()
        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))
        let child = store.accounts.first { $0.upstream == "c1" }!
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer sk-team")
            return .json(kitchenThree)
        }

        let runtime = ProviderCatalog.make(
            accounts: [kitchen, child], vault: store.credentialVault, http: http,
            kitchenHost: URL(string: "https://kitchen.example.com")!)

        XCTAssertEqual(runtime.count, 2)
        let result = await runtime[1].refresh()
        guard case .success(let snapshot) = result else { return XCTFail("the connection card should read: \(result)") }
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Cost 30 Days"])
        XCTAssertEqual(http.requests.map(\.url.path), ["/openusage/v1/accounts"])
    }

    func testAKitchenReadServesEveryCardFromOneRequest() async throws {
        let (store, kitchen) = makeStore()
        try store.syncKitchenConnections(of: kitchen.id, to: connections(kitchenThree))
        let http = RoutingHTTPClient { _ in .json(kitchenThree) }
        let runtimes = ProviderCatalog.make(
            accounts: store.accounts, vault: store.credentialVault, http: http,
            kitchenHost: URL(string: "https://kitchen.example.com")!)

        for runtime in runtimes { _ = await runtime.refresh() }

        XCTAssertEqual(http.requests.filter { $0.url.path == "/openusage/v1/accounts" }.count, 1,
                       "four cards, one call: the answer is shared for the refresh interval")
    }
}
