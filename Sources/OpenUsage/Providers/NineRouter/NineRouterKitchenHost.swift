import Foundation

/// Where the team's 9router Kitchen lives. The host is not in the source: a packaged team build carries it in
/// its Info.plist (`NineRouterKitchenURL`, written at packaging time), so the public fork names no server.
/// A build without one leaves the kind selectable but inert: it sends no request.
enum NineRouterKitchenHost {
    static let infoPlistKey = "NineRouterKitchenURL"
    static let notConfigured = "9router Kitchen isn't configured in this build."

    /// The host from `main`'s Info.plist, else from the `.app` that contains `executableURL`: the bundled
    /// command line has no bundle of its own, so `Bundle.main` alone misses it there.
    static func baseURL(main: Bundle = .main, executableURL: URL? = Bundle.main.executableURL) -> URL? {
        if let value = main.object(forInfoDictionaryKey: infoPlistKey) as? String, let url = validated(value) { return url }
        guard let appURL = executableURL.flatMap(ContainingAppBundle.url(for:)),
              let value = Bundle(url: appURL)?.object(forInfoDictionaryKey: infoPlistKey) as? String else { return nil }
        return validated(value)
    }

    /// An http(s) URL with a host, without a trailing slash; nil for anything else.
    static func validated(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
