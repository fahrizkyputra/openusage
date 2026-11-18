import Foundation

/// The team API keys an earlier team build saved in OpenUsage's own config folder, imported once. It follows
/// the upstream import of the OpenRouter and Z.ai keys (`APIKeyV1Files`): only files this app family wrote are
/// read (never another tool's login), a key becomes an account only after the server accepts it, a provider
/// is done once its key is saved, refused, or turned off, and a failed check is tried again next launch.
/// The files are left as they were so a downgrade finds them.
enum TeamKeyImport {
    static let importedKey = "openusage.teamKeyFiles.v1.imported"

    private static let files: [(kind: ProviderKind, file: String)] = [
        (.ninerouterKitchen, "9router-kitchen.json"), (.commandcode, "commandcode.json"), (.kimi, "kimi.json")
    ]

    @MainActor
    static func importOnce(
        into accounts: AccountStore,
        defaults: UserDefaults = .standard,
        home: URL = .homeDirectory,
        http: any HTTPClient = URLSessionHTTPClient(),
        kitchenHost: URL? = NineRouterKitchenHost.baseURL(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async {
        guard bundleIdentifier != APIKeyV1Files.developmentBundleIdentifier else { return }
        for (kind, file) in files {
            let doneKey = "\(importedKey).\(kind.rawValue)"
            guard !defaults.bool(forKey: doneKey) else { continue }
            guard kind != .ninerouterKitchen || kitchenHost != nil else { continue }
            if !wasTurnedOff(kind, in: defaults),
               !accounts.accounts.contains(where: { $0.kind == kind }),
               let key = key(at: home.appending(path: ".config/openusage/\(file)")) {
                let runtime = AccountProviderRuntime(
                    account: Account(kind: kind, label: kind.displayName), vault: accounts.credentialVault,
                    http: http, kitchenHost: kitchenHost)
                do {
                    try await runtime.readSnapshot(using: .apiKey(key))
                    if !accounts.accounts.contains(where: { $0.kind == kind }) {
                        let account = accounts.add(kind: kind, label: kind.displayName, credential: .apiKey(key))
                        guard accounts.accounts.contains(where: { $0.id == account.id }) else {
                            AppLog.warn(.config, "could not save the \(kind.displayName) key in \(file), trying again next launch")
                            continue
                        }
                        if kind == .ninerouterKitchen, let host = kitchenHost {
                            await syncConnections(of: account.id, key: key, host: host, http: http, into: accounts)
                        }
                        AppLog.notice(.config, "imported the \(kind.displayName) key saved in \(file)")
                    }
                } catch ProviderError.keyRejected(let message) {
                    AppLog.warn(.config, "skipped the \(kind.displayName) key saved in \(file): \(message)")
                } catch {
                    AppLog.warn(.config, "could not check the \(kind.displayName) key saved in \(file), trying again next launch: \(error.localizedDescription)")
                    continue
                }
            }
            defaults.set(true, forKey: doneKey)
        }
    }

    /// 0.7 listed the Kitchen as `9router-kitchen`; every other team provider kept its kind name.
    private static func wasTurnedOff(_ kind: ProviderKind, in defaults: UserDefaults) -> Bool {
        if APIKeyV1Files.wasTurnedOff(kind, in: defaults) == false { return false }
        guard kind == .ninerouterKitchen else { return true }
        let legacy = "9router-kitchen"
        if let enabled = defaults.stringArray(forKey: "openusage.enabledProviders.v1") {
            return !enabled.contains(legacy)
        }
        return defaults.stringArray(forKey: "openusage.disabledProviders.v1")?.contains(legacy) ?? false
    }

    /// The Kitchen's connections, as accounts, once its key is known to work. A failed read leaves the account
    /// without them; the next refresh adds them.
    @MainActor
    private static func syncConnections(
        of id: UUID, key: String, host: URL, http: any HTTPClient, into accounts: AccountStore
    ) async {
        let client = NineRouterUsageClient(http: http, baseURL: host)
        guard let response = try? await client.accounts(apiKey: key),
              let list = NineRouterUsageMapper.connections(response.body) else { return }
        try? accounts.syncKitchenConnections(of: id, to: list)
    }

    /// `{"apiKey": "…"}` as the team key editor wrote it, or a bare key on one line.
    private static func key(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let raw = (try? JSONDecoder().decode(Saved.self, from: data).apiKey)
            ?? (data.first == UInt8(ascii: "{") ? nil : String(data: data, encoding: .utf8))
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private struct Saved: Decodable {
        let apiKey: String
    }
}
