---
name: openusage-add-provider
description: Use when adding or changing a usage provider in this OpenUsage fork (a new card, new metrics, spend tiles that should feed Total Spend, or a provider that reads a local gateway or remote proxy), or when a provider change fails CI on LocalLimitsAPITests / UsageHistoryClassificationTests.
---

# Add a provider to OpenUsage (fork)

Read `docs/adding-a-provider.md` and `AGENTS.md` first. This skill covers what they don't say, and
what bit us in this fork. Each step ends on a **green** line.

## 1. Base and branch

```bash
git fetch upstream && git checkout -b feat/<provider> upstream/main
```

Start from **current** `upstream/main`. A stale base shows up later as unrelated diffs (e.g. a
pricing entry "removed") when comparing against `origin/main`. Keep the generic provider on its own
branch, so it can become an upstream PR. Anything organisation-specific goes on a branch stacked on
top, or into build-time config.

**Green:** `git merge-base --is-ancestor upstream/main HEAD`.

## 2. Keep it public-clean

This fork is **public**. Hostnames, bundle ids, and other organisation values never go into source,
tests, docs, or commit messages. Read them at runtime (Info.plist key written at packaging time, or
an environment variable), and use `example.com` / `com.example.*` in tests and docs. Before every
push:

```bash
git grep -ciE '<org-pattern>' -- . | wc -l          # 0
git log --format=%B upstream/main..HEAD | grep -ciE '<org-pattern>'   # 0
```

**Green:** both are `0`.

## 3. Module

`Sources/OpenUsage/Providers/<Name>/`: auth store, usage client, mapper, and a `ProviderRuntime`
with both `refresh()` and `hasLocalCredentials()`. The probe reads the same sources as `refresh()`,
off the main actor (`loadOffMainActor`). A provider that needs a host **and** a key probes both, so
a key alone doesn't auto-enable an unconfigured card.

- **Errors:** a typed error enum, plus a `CategorizedError` conformance in
  `Providers/ErrorCategory.swift` (the switch is exhaustive; the compile fails if you forget).
- **User-supplied secret:** conform to `APIKeyManaging`, backed by `UserAPIKeyStore`. Override
  `apiKeyTitle` / `apiKeyPlaceholder` when the secret isn't an "API Key".
- **Loopback server:** plain `URLSessionHTTPClient` works for `http://127.0.0.1`. There's no ATS
  exception to add.
- **Bundled CLI:** the helper `OpenUsage.app/Contents/Helpers/openusage` has no bundle of its own,
  so `Bundle.main` Info.plist lookups return nil there. Fall back to
  `ContainingAppBundle.url(for: Bundle.main.executableURL)`.

**Green:** the module compiles (in CI, see step 7), and every error case maps to a category.

## 4. Register: every place, not just one

| Where | What |
|---|---|
| `Providers/ProviderCatalog.swift` | Add the runtime to the list. This is where registration actually happens: `AppContainer` and the CLI both call `ProviderCatalog.make`, despite what the upstream doc says |
| `Stores/DefaultLayout.swift` | `metricIDs` (enabled), `pinnedMetricIDs` (≤2 per provider), `expandedMetricIDs` (below the caret). Confirm these four defaults with the owner: enabled, visible vs. on-demand, pinned, and order |
| `Support/ProviderIconShape.swift` | SF Symbol fallback in `symbolFallback(for:)` |
| `Resources/ProviderIcons/<id>.svg` | Single `<path>` with `fill="currentColor"`. No `<text>`, gradients, or strokes (the renderer only reads `d=`). Convert text to outlines and remove overlaps first |
| `Tests/…/LocalLimitsAPITests.swift` | Add `"<id>": [<exported limit keys>]` to the expected map |
| `Tests/…/ProviderMarksTests.swift` | Add the id if you ship an SVG |
| `docs/providers/<id>.md`, `docs/README.md`, `README.md` | Provider page, and list entries |

**Green:** every row done, and `git grep -n '"<id>' Sources Tests` hits each file above.

## 5. Spend and Total Spend

To join the **Total Spend** card, a provider needs the shared spend tiles, not look-alike rows:

- Use `WidgetDescriptor.spendTiles(provider:valueTooltipNote:)`. Its labels must be exactly
  `Today` / `Yesterday` / `Last 30 Days`, and each `.values` line carries dollars and
  `count` + `label: "tokens"`.
- Add `.usageTrend(provider:)` with **exactly one** `.exportingHistory(scope:estimatedCost:sourceNote:)`,
  and set `usageHistory` on the snapshot. `.machineLocal` is data this Mac produced (iCloud sync sums
  Macs). `.accountWide` is a shared server total (never summed).
- Add the provider to `UsageHistoryClassificationTests` with its scope.
- Build lines with `SpendTileMapper.appendTokenUsage` + `appendUsageTrend`. It keys days by *this
  Mac's* calendar, so pass a `now` anchored to the source's last day if the source uses another zone.
- `estimated: true` when the dollars are priced from tokens rather than billed.
- Overlap with another provider (e.g. a gateway that proxies Claude): users can turn off
  "Include in Total Spend" per provider. Mention it in the provider doc.

**Green:** `TotalSpendAggregator.total` sums the provider in a test, and the classification test
passes.

## 6. Tests

Mapper tests on real sample payloads, provider tests through `RoutingHTTPClient` (assert paths,
query, and auth header), plus a `WidgetDataStore` test when the snapshot carries extra fields.
Pin `now` to a fixed local noon so Today / Yesterday don't flake.

## 7. Verify in CI

This Mac may lack the toolchain (Swift 6.2 + macOS 26 SDK), so don't claim a build passes without a
run. Push the branch and run CI through a draft PR in the fork, or through the private build repo.
Read the `Executed N tests … failures` line and any `: error` lines.

**Green:** `0 failures`, and the provider's own test cases are listed as passed.
