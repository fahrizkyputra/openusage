# Command Code

Tracks [Command Code](https://commandcode.ai/) plan limits, credits, and billed spend: the same numbers
the CLI's `/usage` view shows.

## What it tracks

| Metric | Meaning |
|---|---|
| 5-hour | Dollars used in the rolling 5-hour window, against its cap (e.g. $14 on GOAT) |
| Weekly | Dollars used in the rolling weekly window, against its cap (e.g. $35 on GOAT) |
| Monthly | The plan's monthly credits used this billing period, resetting when the period renews |
| Extra credits | Purchased and free credits left. The windows never throttle these |
| Requests | Requests made this billing period |
| Today / Yesterday | Billed cost and tokens for the day. Counted in **Total Spend** |

The card's header shows the plan (Go, GOAT, Pro, Max, …). The windows open on your first request and
reset a fixed time later, so their reset times move with your usage.

There is no **Last 30 Days** row: Command Code's API can't report usage from before the current billing
period. For the same reason, Today or Yesterday is left out on the day a billing period starts, rather
than showing a partial figure.

If you also use Command Code through a gateway such as 9router, its spend shows up on both cards. Turn
off **Include in Total Spend** on one of them so Total Spend doesn't count it twice.

## Where the key comes from

OpenUsage uses the first key it finds:

1. A key saved in **Customize → Command Code → API Key** (stored in `~/.config/openusage/commandcode.json`).
2. The `COMMAND_CODE_API_KEY` environment variable.
3. The Command Code CLI login in `~/.commandcode/auth.json`.

If the CLI is logged in, nothing else is needed. OpenUsage only reads the CLI's file; clearing the key
in the app never touches it. Create a key in Command Code Studio if you don't use the CLI.

## Under the hood

Read-only `GET` requests to `https://api.commandcode.ai` (override with `COMMAND_CODE_API_BASE_URL`),
with the key as a Bearer token:

- `/alpha/whoami?limits=1`: whether the key belongs to an organization (its id scopes the calls below).
- `/alpha/billing/credits`: credits left and the 5-hour / weekly windows.
- `/alpha/billing/subscriptions`: plan and billing period.
- `/alpha/usage/summary?since=…`: requests, tokens, and cost since the period start, today, and
  yesterday.

The monthly allocation per plan matches the CLI's own table. For a plan it doesn't know, the Monthly
meter is built from the credits left.
