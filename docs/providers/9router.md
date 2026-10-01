# 9router

Tracks spend and plan limits of a local [9router](https://github.com/decolua/9router) gateway — the
proxy that rotates your AI coding requests across several upstream accounts.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | The tightest 5-hour window across every active upstream connection |
| Weekly | The tightest weekly window across every active upstream connection |
| Accounts | How many upstream accounts are active, and how many are limited ("4 active · 1 limited"). Hover for the list |
| Usage Trend | Tokens per day over the last 30 days |
| Today / Yesterday / Last 30 Days | Cost and tokens routed through 9router; they also feed [Total Spend](../dashboard.md#total-spend) |

9router spreads requests over several accounts, so Session and Weekly show the account closest to its
limit — the one that will throttle you first — and name it beside the row title (e.g. "Weekly · Account 1").
Each meter is picked on its own, so Session and Weekly can name different accounts. The name is the
connection's label in the 9router dashboard; when two active connections share a label, the provider is
added ("Account 1 (claude)"). Model-specific windows and credit balances are left out.
Connections that report no plan quota (plain API keys, custom endpoints) only count toward spend.

Hover the **Accounts** value to see every active connection: its name and provider, Session and
Weekly %, cost over the last 30 days, and its routing state in 9router: **OK**; **Cooling down** (9router
skips one model on it for a short while); **Paused** (9router stopped routing to it after an error —
its plan quota is unaffected; test the connection in the 9router dashboard to resume it); **No
balance**; or **Auth error**. The raw error text is never shown. Accounts with a plan quota are listed tightest first, the rest by cost.

Cost is what 9router prices each request at (API rates), so it's marked as an estimate: on a
subscription it's API-equivalent value, not your bill. Days follow 9router's own clock. Hovering
Today or Last 30 Days lists the top models; Yesterday shows totals only, because 9router ranks
models per period, not per day. With iCloud Sync on, 9router history from your Macs is combined,
like Claude's.

If Claude Code (or another tracked client) sends its requests through 9router, the same usage shows
on both cards. Turn off **Include in Total Spend** for one of them so the total isn't doubled.

## Where credentials come from

Nothing to set up. 9router's own CLI reaches the dashboard with a token derived from two files 9router
writes the first time it starts:

- `~/.9router/machine-id`
- `~/.9router/auth/cli-secret`

OpenUsage derives the same token from those files and only sends it to the local 9router server.

Optional overrides (shell profile):

- `NINEROUTER_DATA_DIR` — 9router data directory, if you start 9router with a custom `DATA_DIR`.
- `NINEROUTER_URL` — server address, default `http://127.0.0.1:20128`.

## Troubleshooting

- **"9router not found"** — 9router has never run on this Mac. Start it once with `9router`.
- **"Couldn't reach 9router"** — the server isn't running, or listens on another port (set `NINEROUTER_URL`).
- **"9router rejected the local CLI token"** — the secret changed or the data directory doesn't match
  the running server. Restart 9router, and check `NINEROUTER_DATA_DIR`.
- **No Session / Weekly rows** — none of the active connections report a plan quota.

## Under the hood

`GET` calls against the local server, each with the `x-9r-cli-token` header:

- `/api/usage/chart?period=30d` — required; one point per day (cost, tokens) for the spend tiles,
  Usage Trend, and Total Spend.
- `/api/usage/stats?period=today|30d` — best-effort; the top models (`byModel`) for the hover lists.
- `/api/providers` — best-effort; the list of active connections.
- `/api/usage/<connectionId>` — best-effort, once per active connection; its `session` and `weekly`
  quotas feed the Session and Weekly meters. A failing connection is skipped.
