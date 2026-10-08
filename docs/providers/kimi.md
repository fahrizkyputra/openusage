# Kimi

Tracks [Kimi for Coding](https://www.kimi.com) subscription usage: the rolling session rate-limit
window and the weekly request quota, plus the membership level as the plan name.

## Credentials

Kimi has no companion CLI or app that stores a credential on the machine, so OpenUsage manages an
API key directly — same pattern as OpenRouter and Z.ai. Add the key in **Settings → API Keys**, or
place it yourself:

- environment variable: `KIMI_API_KEY`
- config file: `~/.config/openusage/kimi.json` (`{"apiKey": "sk-kimi-…"}`) or a plain-text file
  containing only the key

A saved config file overrides the environment variable.

## What it tracks

One required endpoint: `GET https://api.kimi.com/coding/v1/usages` (Bearer auth); plus the optional
`GET https://api.kimi.com/coding/v1/me` for the plan name.

- **Session** — the sub-daily rolling rate-limit window (`limits[]` entry, e.g. the 300-minute
  window), shown as percent used with the real reset time.
- **Weekly** — the weekly request quota (top-level `usage`), percent used, resets at `resetTime`.
- **Plan** — `user_level_name` from `GET /coding/v1/me` (e.g. "Vivace"), best-effort: if that call
  fails the meters still render, just without a plan label. Do not use `usages.user.membership.level`
  (`LEVEL_STANDARD`) — that enum is the coding product version, not the subscription tier.

## Local harness usage

Beyond the live quota, the card folds in Kimi traffic from local harness logs:

- **pi** — `~/.pi/agent/sessions` JSONL; pi records an authoritative per-message cost, used as-is.
- **OpenCode** — BYO-key `kimi-for-coding` provider rows in OpenCode's database; those record $0, so
  tokens are priced through the shared pricing engine (`k3` → `kimi-k3` rates, `kimi-for-coding` →
  `kimi-k2.7-code`). OpenCode-hosted kimi models (`kimi-k2.5-free` etc.) bill to OpenCode and are
  excluded on purpose.

These drive the Usage Trend row and the Today / Yesterday / Last 30 Days spend tiles.

## Errors

- **No key** — set `KIMI_API_KEY` or save the key in Settings.
- **Invalid key** — the endpoint answered 401/403; check the key.
- **No data** — the account returned no quota sections (nothing to meter).
