import XCTest
@testable import OpenUsage

/// A team build's 9router Kitchen card starts on without credentials, so it can ask for its API key.
@MainActor
final class AlwaysOnProviderTests: XCTestCase {
    private func defaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageTests.AlwaysOn.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func kitchen(host: String? = "https://kitchen.example.com", key: String? = nil) -> NineRouterKitchenProvider {
        let files = FakeFiles(key.map { [NineRouterKitchenAuthStore.configPaths[0]: #"{"apiKey":"\#($0)"}"#] } ?? [:])
        return NineRouterKitchenProvider(
            authStore: NineRouterKitchenAuthStore(files: files, environment: FakeEnvironment(), bundledBaseURL: host)
        )
    }

    func testKitchenIsAlwaysOnOnlyInBuildsWithAHost() {
        XCTAssertTrue(kitchen().enablesWithoutCredentials)
        XCTAssertFalse(kitchen(host: nil).enablesWithoutCredentials)
        XCTAssertFalse(NineRouterProvider().enablesWithoutCredentials)
        XCTAssertFalse(ClaudeProvider().enablesWithoutCredentials)
    }

    func testFreshInstallEnablesKitchenWithoutAKeyAlongsideDetectedProviders() async {
        let enablement = ProviderEnablementStore(defaults: defaults("fresh"))
        let providers: [ProviderRuntime] = [ProbeStub("claude", true), ProbeStub("codex", false),
                                            ProbeStub("cursor", false), kitchen()]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: OnboardingStore(defaults: defaults("fresh-o"))
        )
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor", "9router-kitchen"], "on in the fallback too")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "9router-kitchen"])
    }

    func testFreshInstallWithNothingDetectedKeepsFallbackPlusKitchen() async {
        let enablement = ProviderEnablementStore(defaults: defaults("none"))
        let providers: [ProviderRuntime] = [ProbeStub("claude", false), ProbeStub("codex", false),
                                            ProbeStub("cursor", false), kitchen()]
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: OnboardingStore(defaults: defaults("none-o"))
        )
        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor", "9router-kitchen"])
    }

    func testBuildWithoutHostKeepsKitchenOff() async {
        let enablement = ProviderEnablementStore(defaults: defaults("nohost"))
        let providers: [ProviderRuntime] = [ProbeStub("claude", true), kitchen(host: nil, key: "sk-x")]
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: OnboardingStore(defaults: defaults("nohost-o"))
        )
        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude"])
    }

    func testCatchUpTurnsKitchenOnOnceForExistingInstallsWithoutAKey() async {
        let store = defaults("catchup")
        let enablement = ProviderEnablementStore(defaults: defaults("catchup-e"))
        enablement.seedEnabledProviders(["claude"])
        let providers: [ProviderRuntime] = [ProbeStub("claude", true), kitchen()]

        await AlwaysOnProviderCatchUp.runIfNeeded(providers: providers, enablement: enablement, defaults: store)
        XCTAssertTrue(enablement.isEnabled("9router-kitchen"))

        // The user turns it off: a later launch must respect that.
        enablement.setEnabled(false, for: "9router-kitchen")
        await AlwaysOnProviderCatchUp.runIfNeeded(providers: providers, enablement: enablement, defaults: store)
        XCTAssertFalse(enablement.isEnabled("9router-kitchen"))
    }

    func testCatchUpLeavesUsersWhoAlreadyHaveAKeyAlone() async {
        let store = defaults("haskey")
        let enablement = ProviderEnablementStore(defaults: defaults("haskey-e"))
        enablement.seedEnabledProviders(["claude"])

        await AlwaysOnProviderCatchUp.runIfNeeded(providers: [kitchen(key: "sk-team")], enablement: enablement, defaults: store)

        XCTAssertFalse(enablement.isEnabled("9router-kitchen"), "a user with a key who turned Kitchen off chose that")
        XCTAssertEqual(store.stringArray(forKey: AlwaysOnProviderCatchUp.doneKey), ["9router-kitchen"])
    }

    func testMissingKeyCardSaysSo() async {
        let snapshot = await kitchen().refresh()
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return XCTFail("expected error badge") }
        XCTAssertTrue(text.hasPrefix("No 9router Kitchen API key"))
    }
}

@MainActor
private final class ProbeStub: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let has: Bool
    init(_ id: String, _ has: Bool) {
        provider = Provider(id: id, displayName: id, icon: .providerMark(id))
        self.has = has
    }
    func refresh() async -> ProviderSnapshot { ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date()) }
    func hasLocalCredentials() async -> Bool { has }
}
