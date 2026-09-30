import Foundation

/// Metrics enabled on first launch. Core quota meters and trends stay visible above the fold, while
/// balances, reset details, and spend-history rows are enabled but tucked behind each provider's caret.
/// `LayoutStore` filters this to whatever the active registry actually knows, so registries that don't
/// define an ID (e.g. the test fixtures) silently ignore it. The provider-section order isn't seeded
/// here: an empty saved order reconciles to plain registry order in `LayoutStore`.
enum DefaultLayout {
    /// Account cards inherit their family's existing defaults. Keep the migration baseline unexpanded
    /// so a newly discovered card also receives its metrics on an existing installation.
    static func expandingAccounts(_ metricIDs: [String], providerIDs: [String]) -> [String] {
        metricIDs.flatMap { metricID -> [String] in
            guard let separator = metricID.firstIndex(of: ".") else { return [metricID] }
            let family = String(metricID[..<separator])
            let suffix = metricID[separator...]
            let additionalIDs = providerIDs.filter {
                $0 != family && ProviderAccountID.family(of: $0) == family
            }
            return [metricID] + additionalIDs.map { "\($0)\(suffix)" }
        }
    }

    static let metricIDs: [String] = [
        "9router.session", "9router.weekly", "9router.accounts", "9router.trend",
        "9router.today", "9router.yesterday", "9router.last30",
        "9router-kitchen.session", "9router-kitchen.weekly", "9router-kitchen.accounts", "9router-kitchen.trend",
        "9router-kitchen.today", "9router-kitchen.yesterday", "9router-kitchen.last30",

        "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.claude", "antigravity.claudeWeekly",
        "antigravity.trend", "antigravity.today", "antigravity.yesterday", "antigravity.last30",

        "claude.session", "claude.weekly", "claude.fable", "claude.trend",
        "claude.extra", "claude.rateLimitResets", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.spark", "codex.sparkWeekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30",

        "copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend",
        "copilot.chat", "copilot.completions",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.weekly", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "ollama.session", "ollama.weekly", "ollama.monthly", "ollama.last4Weeks",

        "opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend",
        "opencode.today", "opencode.yesterday", "opencode.last30",

        "openrouter.credits", "openrouter.balance",
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",

        "zai.session", "zai.weekly", "zai.webSearches"
    ]

    /// Frozen snapshot of the default-on metrics from the release that introduced default seeding.
    /// Existing users without a seeded-defaults key are treated as if these were already offered, so
    /// past opt-outs stay off while future additions to `metricIDs` can appear automatically once.
    static let migrationBaselineMetricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "claude.extra", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.creditsUsed", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
    ]

    /// Metrics pinned to the menu bar on first launch, so the app shows real numbers out of the box
    /// instead of a lone icon. Two per provider for Antigravity, Claude, Codex, and Cursor — the
    /// per-provider cap (`LayoutStore.maxPinsPerProvider`). Filtered to the active registry by
    /// `LayoutStore`, like `metricIDs`.
    static let pinnedMetricIDs: [String] = [
        "9router.session", "9router.weekly",
        "9router-kitchen.session", "9router-kitchen.weekly",
        "antigravity.geminiPro", "antigravity.geminiWeekly",
        "claude.session", "claude.weekly",
        "codex.session", "codex.weekly",
        "cursor.auto", "cursor.api",
        "copilot.premium",
        "ollama.session", "ollama.weekly",
        "openrouter.credits",
        "zai.session", "zai.weekly"
    ]

    /// Metrics placed in the per-provider On Demand section on a fresh install. This is
    /// membership, not enablement: optional disabled rows like Sonnet or Cursor Requests/Credits are
    /// listed here so if the user enables them later they appear below the caret by default.
    /// Filtered to the active registry by `LayoutStore`, and only seeded on a genuinely fresh launch
    /// (existing layouts keep everything always-shown unless they reset customization).
    static let expandedMetricIDs: [String] = [
        // 9router: Session, Weekly (tightest window across connections), and Usage Trend stay above
        // the fold; the spend tiles sit below the caret, like Claude and Codex.
        "9router.today", "9router.yesterday", "9router.last30",
        "9router-kitchen.today", "9router-kitchen.yesterday", "9router-kitchen.last30",
        // Antigravity: the Gemini pool pair and usage trend stay above the fold; the non-Gemini
        // pool pair and spend-history rows sit below the caret, matching the other local scanners.
        "antigravity.claude", "antigravity.claudeWeekly",
        "antigravity.today", "antigravity.yesterday", "antigravity.last30",
        // Claude's core meters (Session, Weekly, Fable, Extra, Usage Trend) stay above the fold;
        // optional Sonnet, reset grants, and spend-history rows sit below the caret.
        "claude.sonnet", "claude.rateLimitResets", "claude.today", "claude.yesterday", "claude.last30",
        // Codex's core Session/Weekly meters and Usage Trend stay above the fold; Spark (the optional
        // model-specific limits), credits, reset details, and spend rows sit below the caret.
        "codex.spark", "codex.sparkWeekly",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",
        "cursor.grokBot", "cursor.onDemand", "cursor.requests", "cursor.credits",
        "cursor.today", "cursor.yesterday", "cursor.last30",
        // Copilot: Credits (the metered premium pool) + Extra Usage stay above the fold; the org
        // billing pair (org-managed Business/Enterprise seats) and Chat + Completions sit below the
        // caret. Chat/Completions carry real counts on free only — on paid they're unlimited
        // (suppressed), so they read "No data" there.
        "copilot.orgCredits", "copilot.orgSpend", "copilot.chat", "copilot.completions",
        "devin.extra",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",
        // Ollama: Session, Weekly, and Monthly stay above the fold; the rolling four-week spend total
        // (always $0.00 on a subscription, real only for pay-as-you-go) sits below the caret.
        "ollama.last4Weeks",
        // OpenCode: the three Go caps (Session/Weekly/Monthly) and Usage Trend stay above the fold —
        // matching every other provider — with the spend tiles (Today/Yesterday/Last 30 Days) below.
        "opencode.today", "opencode.yesterday", "opencode.last30",
        // OpenRouter: Credits meter + Balance stay above the fold; period spend and the per-key cap
        // sit below the caret.
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",
        // Z.ai: Session meter stays above the fold; Web Searches (monthly count) sits below the caret.
        "zai.webSearches"
    ]
}
