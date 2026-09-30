import XCTest
@testable import OpenUsage

private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    var result = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    var calls: [(String, [String], [String: String])] = []
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        calls.append((executable, arguments, environment))
        return result
    }
}

private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

@MainActor
final class TeamUpdateCheckerTests: XCTestCase {
    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(TeamUpdateChecker.isNewer("v0.7.0-team.612", than: "0.7.0-team.611"))
        XCTAssertTrue(TeamUpdateChecker.isNewer("v0.7.0-team.1000", than: "0.7.0-team.999"))
        XCTAssertTrue(TeamUpdateChecker.isNewer("v0.8.0-team.1", than: "0.7.0-team.611"))
        XCTAssertFalse(TeamUpdateChecker.isNewer("v0.7.0-team.611", than: "0.7.0-team.611"))
        XCTAssertFalse(TeamUpdateChecker.isNewer("v0.7.0-team.610", than: "0.7.0-team.611"))
        XCTAssertFalse(TeamUpdateChecker.isNewer("latest", than: "0.7.0-team.611"))
    }

    func testBannerFollowsTheLatestRelease() async {
        let latest = Box<TeamUpdateChecker.Release?>(.init(version: "v0.7.0-team.612", notes: "- new"))
        let checker = TeamUpdateChecker(repo: "acme/openusage-team", currentVersion: "0.7.0-team.611") { _ in latest.value }

        await checker.check()
        XCTAssertEqual(checker.available?.version, "v0.7.0-team.612")
        XCTAssertEqual(checker.agentPrompt, "update to the latest version https://github.com/acme/openusage-team")

        latest.value = .init(version: "v0.7.0-team.611", notes: "")
        await checker.check()
        XCTAssertNil(checker.available, "same version as the running build: no banner")

        latest.value = nil
        latest.value = .init(version: "v0.7.0-team.613", notes: "")
        await checker.check()
        XCTAssertEqual(checker.available?.version, "v0.7.0-team.613")
    }

    func testAFailedCheckKeepsTheLastAnswer() async {
        let latest = Box<TeamUpdateChecker.Release?>(.init(version: "v0.7.0-team.612", notes: ""))
        let checker = TeamUpdateChecker(repo: "acme/openusage-team", currentVersion: "0.7.0-team.611") { _ in latest.value }
        await checker.check()
        latest.value = nil // gh missing / offline
        await checker.check()
        XCTAssertEqual(checker.available?.version, "v0.7.0-team.612", "a transient failure must not hide the banner")
    }

    func testInertWithoutAConfiguredRepo() async {
        let calls = Box(0)
        let checker = TeamUpdateChecker(repo: nil, currentVersion: "0.7.0-team.611") { _ in
            calls.value += 1
            return .init(version: "v9.9.9", notes: "")
        }
        checker.start()
        await checker.check()
        XCTAssertNil(checker.available)
        XCTAssertNil(checker.agentPrompt)
        XCTAssertEqual(calls.value, 0, "no gh call without TeamUpdateRepo in the Info.plist")
    }

    func testReleaseNotesSummaryDropsHeadingsAndBlankLinesAndCaps() {
        let notes = "## Changes\n\n- one\n- two\n\n### More\n" + (3...20).map { "- \($0)" }.joined(separator: "\n")
        let summary = TeamUpdateChecker.summary(of: notes)
        XCTAssertEqual(summary.first, "- one")
        XCTAssertEqual(summary.count, 8)
        XCTAssertFalse(summary.contains { $0.hasPrefix("#") })
    }

    func testGitHubCLIParsesLatestReleaseAndSkipsDraftsAndPrereleases() {
        XCTAssertEqual(
            GitHubCLIReleaseSource.parse(Data(#"{"tag_name":"v0.7.0-team.612","body":"- x","draft":false,"prerelease":false}"#.utf8)),
            .init(version: "v0.7.0-team.612", notes: "- x")
        )
        XCTAssertNil(GitHubCLIReleaseSource.parse(Data(#"{"tag_name":"v1","prerelease":true}"#.utf8)))
        XCTAssertNil(GitHubCLIReleaseSource.parse(Data(#"{"message":"Not Found"}"#.utf8)))
    }

    func testGitHubCLIRunsGhWithTheLoginShellEnvironment() {
        let runner = FakeRunner()
        runner.result = ProcessResult(exitCode: 0, stdout: #"{"tag_name":"v0.7.0-team.612","body":""}"#, stderr: "")
        let source = GitHubCLIReleaseSource(
            runner: runner,
            environment: FakeEnvironment(["PATH": "/custom/bin:/usr/bin", "HOME": "/Users/me", "GH_TOKEN": "t"]),
            fileExists: { $0 == "/custom/bin/gh" }
        )

        XCTAssertEqual(source.latest(repo: "acme/openusage-team")?.version, "v0.7.0-team.612")
        let call = try? XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call?.0, "/custom/bin/gh")
        XCTAssertEqual(call?.1, ["api", "repos/acme/openusage-team/releases/latest"])
        XCTAssertEqual(call?.2["HOME"], "/Users/me")
        XCTAssertEqual(call?.2["GH_TOKEN"], "t")
        XCTAssertEqual(call?.2["GH_PROMPT_DISABLED"], "1")
    }

    func testGitHubCLIFailuresReturnNil() {
        let runner = FakeRunner()
        runner.result = ProcessResult(exitCode: 1, stdout: "", stderr: "HTTP 404")
        let loggedOut = GitHubCLIReleaseSource(runner: runner, environment: FakeEnvironment(), fileExists: { $0 == "/opt/homebrew/bin/gh" })
        XCTAssertNil(loggedOut.latest(repo: "acme/openusage-team"))

        let noGH = GitHubCLIReleaseSource(runner: runner, environment: FakeEnvironment(), fileExists: { _ in false })
        runner.calls.removeAll()
        XCTAssertNil(noGH.latest(repo: "acme/openusage-team"))
        XCTAssertTrue(runner.calls.isEmpty, "no gh binary, no launch")
    }

    func testBundledRepoRequiresOwnerSlashName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ value: String) throws -> Bundle {
            let app = root.appendingPathComponent("\(UUID().uuidString).app/Contents")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "com.example.t", TeamUpdateChecker.infoPlistKey: value]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: app.deletingLastPathComponent()))
        }
        XCTAssertEqual(TeamUpdateChecker.bundledRepo(main: try bundle("acme/openusage-team")), "acme/openusage-team")
        XCTAssertNil(TeamUpdateChecker.bundledRepo(main: try bundle("acme/x; rm -rf /")))
        XCTAssertNil(TeamUpdateChecker.bundledRepo(main: try bundle("")))
    }
}
