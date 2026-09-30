import Foundation
import Observation

/// Team builds only: finds a newer release of the team's (private) distribution repo through the user's
/// own GitHub CLI login, and drives the dashboard's "New version available" banner and Update screen.
///
/// The repo is not in the source: a packaged team build carries `TeamUpdateRepo` (`owner/name`) in its
/// Info.plist. Without it the checker is inert — no `gh` call, no banner. Any failure (no `gh`, not
/// logged in, no access, network) is logged and leaves the banner hidden; it is never surfaced to the user.
@MainActor
@Observable
final class TeamUpdateChecker {
    struct Release: Equatable, Sendable {
        var version: String
        var notes: String
    }

    static let infoPlistKey = "TeamUpdateRepo"
    static let interval: TimeInterval = 6 * 60 * 60

    /// Set when the latest release is newer than the running build.
    private(set) var available: Release?

    let repo: String?
    private let currentVersion: String
    private let fetchLatest: @Sendable (String) async -> Release?
    private var loop: Task<Void, Never>?

    init(
        repo: String? = TeamUpdateChecker.bundledRepo(),
        currentVersion: String = AppInfo.version,
        fetchLatest: @escaping @Sendable (String) async -> Release? = { repo in
            await Task.detached(priority: .utility) { GitHubCLIReleaseSource().latest(repo: repo) }.value
        }
    ) {
        self.repo = repo
        self.currentVersion = currentVersion
        self.fetchLatest = fetchLatest
    }

    /// The update prompt the Update screen copies for the user's agent.
    var agentPrompt: String? {
        repo.map { "update to the latest version https://github.com/\($0)" }
    }

    /// Check now, then every `interval`, for the app's lifetime. No-op without a configured repo.
    func start() {
        guard repo != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func check() async {
        guard let repo else { return }
        guard let latest = await fetchLatest(repo) else { return }
        if Self.isNewer(latest.version, than: currentVersion) {
            if available != latest {
                AppLog.info(.updates, "team build: \(latest.version) available (running \(currentVersion))")
            }
            available = latest
        } else {
            available = nil
        }
    }

    // MARK: - Helpers

    static func bundledRepo(main: Bundle = .main) -> String? {
        guard let raw = (main.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    /// `v0.7.0-team.612` vs `0.7.0-team.611`: compare every run of digits numerically, left to right.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = numbers(in: candidate)
        let rhs = numbers(in: current)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(in version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// Release notes trimmed for the Update screen: non-empty lines, markdown headings dropped, capped.
    static func summary(of notes: String, maxLines: Int = 8) -> [String] {
        let lines = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Array(lines.prefix(maxLines))
    }
}

/// Reads the latest release with the user's `gh` login. Blocking; call off the main actor.
struct GitHubCLIReleaseSource: Sendable {
    /// Where Homebrew and the official installer put `gh`. A Finder-launched app has no shell `PATH`.
    static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    var runner: ProcessRunning = SystemProcessRunner()
    var environment: EnvironmentReading = ProcessEnvironmentReader()
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func latest(repo: String) -> TeamUpdateChecker.Release? {
        guard let gh = locateGH() else {
            AppLog.info(.updates, "team build: gh not found; skipping update check")
            return nil
        }
        let result: ProcessResult
        do {
            result = try runner.run(
                executable: gh,
                arguments: ["api", "repos/\(repo)/releases/latest"],
                environment: ghEnvironment(),
                timeout: 20
            )
        } catch {
            AppLog.warn(.updates, "team build: update check failed: \(error.localizedDescription)")
            return nil
        }
        guard result.succeeded else {
            AppLog.warn(.updates, "team build: gh exited \(result.exitCode) (not logged in or no access?)")
            return nil
        }
        return Self.parse(Data(result.stdout.utf8))
    }

    static func parse(_ body: Data) -> TeamUpdateChecker.Release? {
        guard let root = ProviderParse.jsonObject(body),
              let tag = (root["tag_name"] as? String)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty,
              (root["draft"] as? Bool) != true, (root["prerelease"] as? Bool) != true
        else { return nil }
        return .init(version: tag, notes: (root["body"] as? String) ?? "")
    }

    func locateGH() -> String? {
        let shellPath = (environment.value(for: "PATH") ?? "").split(separator: ":").map { "\($0)/gh" }
        return (Self.candidatePaths + shellPath).first(where: fileExists)
    }

    /// `gh` reads its login from the user's config; pass the login shell's HOME/PATH and any token env.
    private func ghEnvironment() -> [String: String] {
        var env: [String: String] = ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]
        for key in ["HOME", "PATH", "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"] {
            if let value = environment.value(for: key) { env[key] = value }
        }
        return env
    }
}
