# Changelog

All notable changes to **DeepSeek Off-Peak Menubar**, newest first.
German changelog: the project history is also documented in the repository of
the original author.

## v2.0.0 (Sep 2026)

- **Localization**: English is now the base language, German ships as a
  translation (`Resources/*.lproj/Localizable.strings`). New `language` config
  key (`auto` | `en` | `de`).
- **Universal binary**: `build.sh` now builds Intel (x86_64) **and** Apple
  Silicon (arm64) and bundles the resources.
- **Public release preparation**: neutral bundle identifier, MIT license,
  English README + German translation, CONTRIBUTING, GitHub Actions workflow.
- New CLI flags `--version` and `--help`.
- Pricing, balance and usage output are localized, including number/currency
  formats (`$0.83` vs `0,83 $`).
- Project home is the `pikasso-eu` organization, bundle identifier
  `org.eu.pikasso.offpeak-menubar` (reverse DNS of pikasso.eu.org).

## v1.5.3 (Sep 2026)

- **Fix**: DSH renamed its session logs to `session.v3.jsonl.zstd`. The scanner
  now accepts every `session*.jsonl.zstd` variant and evaluates only the newest
  file per session directory (the v3 file contains the full history), so active
  sessions – e.g. ones using the vision model – are no longer missed.
- **Fix**: copies/forks of the same session (identical `message.id`) are counted
  only once, so costs are no longer doubled.

## v1.5.2 (Sep 2026)

- **Fix**: `zstd` is now looked up at fixed paths (`/usr/local/bin`,
  `/opt/homebrew/bin`, `/usr/bin`), so the usage analytics also work when the app
  is launched from Finder (which has no shell `PATH`).

## v1.5.1 (Sep 2026)

- **Fix**: running sessions are being written while read; partial `zstd` frames
  are now used instead of reporting the whole file as unreadable.

## v1.5.0 (Sep 2026)

- **New**: usage and cost tracking across all DSH sessions.
  - Reads `~/.dsh/sessions/**/session*.jsonl.zstd`.
  - Splits input into cache hits/misses, output includes reasoning tokens.
  - Prices every request by model and by the tariff valid at that timestamp.
  - Menu section with today / 7 days / total, plus `--cost` for a per-session
    breakdown.
  - New config keys `usageRefreshMinutes`, `eurPerUsd`.

## v1.4.1 (Sep 2026)

- **Fix**: "Start DSH Web" checks whether something already answers on
  `127.0.0.1:3080` and offers to open it instead of failing with `EADDRINUSE`.

## v1.4.0 (Sep 2026)

- **New**: "Start DSH Web" without AppleScript – it writes a `.command` script
  and opens it via LaunchServices, so **no Automation permission** is required.
  Runs the `deepseek` alias from `~/.bashrc` (falls back to
  `npx @deepseek-ai/dsh web`).

## v1.3.1 (Sep 2026)

- **Fix**: "Edit configuration" always opens the JSON file in TextEdit instead of
  the system default app.

## v1.3.0 (Sep 2026)

- **New**: account balance via the official `GET /user/balance` endpoint with
  granted/topped-up amounts, threshold warning and optional menu bar display.
- CLI: `--balance`. Key source: `apiKey` → `apiKeyEnv` → `apiKeyFile`, local only.

## v1.2.0 (Sep 2026)

- Menu bar shows only a coloured dot plus countdown (`● 9h25` instead of
  `● cheap 9:25`).
- Countdown without a colon (`9h30`, `1d5h`, `45m`, `42s`) so it cannot be
  confused with a clock time.
- Menu item "Start DSH Web".

## v1.1.0 (Sep 2026)

- **New**: live-reloaded JSON configuration (windows, weekend rule, reminders).
- **New**: reminders shortly before a tariff change.

## v1.0.0 (Sep 2026)

- First version: menu bar off-peak indicator with countdown.
- Rules: peak Mon–Fri 01:00–04:00 & 06:00–10:00 UTC, all weekend off-peak
  (Beijing time; equivalent to the UTC formulation, covered by the self test).
- CLI: `--text`, `--selftest`, `--config-path`, `--create-config`.
