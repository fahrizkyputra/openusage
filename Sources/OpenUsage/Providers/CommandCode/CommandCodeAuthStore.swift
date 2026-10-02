import Foundation

enum CommandCodeAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Command Code API key. Log in with `cmd login`, set COMMAND_CODE_API_KEY, or add it in Customize → Command Code → API Key."
        case .invalidKey:
            return "Command Code rejected the API key. Create a new one in Command Code Studio."
        case .saveFailed:
            return "Couldn't save the Command Code API key."
        case .deleteFailed:
            return "Couldn't remove the saved Command Code API key."
        }
    }
}

/// Reads the Command Code API key. Order: a key saved in the app (`~/.config/openusage/commandcode.json`,
/// written by the Customize key editor), then `COMMAND_CODE_API_KEY`, then the Command Code CLI's own
/// login (`~/.commandcode/auth.json` → `apiKey`). The CLI file is only ever read, never written or
/// removed: clearing the key in the app clears just the app's copy.
struct CommandCodeAuthStore: Sendable {
    static let configPaths = ["~/.config/openusage/commandcode.json"]
    static let environmentNames = ["COMMAND_CODE_API_KEY"]
    static let cliAuthPath = "~/.commandcode/auth.json"

    private let store: UserAPIKeyStore
    private let files: TextFileAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { CommandCodeAuthError($0) }
        )
    }

    func loadAPIKey() -> String? { store.loadKey() ?? cliKey() }

    /// The in-app editor's status. A CLI login counts as "from your environment": a key the app found
    /// on the machine rather than one saved in the app.
    func keyStatus() -> APIKeyStatus {
        let status = store.keyStatus()
        if status == .notSet, cliKey() != nil { return .fromEnvironment }
        if status == .saved, cliKey() != nil { return .overrideActive }
        return status
    }

    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    private func cliKey() -> String? {
        guard files.exists(Self.cliAuthPath), let text = try? files.readText(Self.cliAuthPath),
              let object = ProviderParse.jsonObject(Data(text.utf8)),
              let key = (object["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }
}
