# Observability Research Note — Snowflake Updates Watch failing (missing Brave API key)

- **When (UTC):** 2026-02-13 15:14
- **Scope:** telemetry, Event Tables, query perf

## Accurate takeaways
- The `web_search` tool (Brave Search) is currently unusable in this OpenClaw environment because **BRAVE_API_KEY is not configured**; calls return `missing_brave_api_key`.
- The cron job **“Snowflake Updates Watch (every 6h)”** depends on “Parallel Search” as a primary approach, but Parallel Search is not currently available as a first-class tool in this runtime.
- Net effect: the updates watch cannot reliably discover new Snowflake FinOps / Native Apps changes, so it may produce **false negatives** (silence even when important changes exist).

## Telemetry schema ideas
- Add an internal “watch health” heartbeat:
  - `last_success_at` (UTC)
  - `last_error` (string)
  - `sources_checked` (count + list)
  - `results_found` (count)
- Emit these into a lightweight log file under `memory/` or a structured JSON under `tmp/` so we can alert on consecutive failures.

## MVP features unlocked (PR-sized)
1) Add configuration + validation for Brave Search:
   - store `BRAVE_API_KEY` in Gateway env and add a startup check that warns if missing.
2) Fallback mode for the cron:
   - if Parallel is not available, use Browser automation to hit a fixed set of authoritative sources (Snowflake Release Notes, Docs “What’s New”, Blog RSS) and diff titles against last run.
3) Add “watch health” notification only on repeated failures (e.g., 3 consecutive runs), so Akhil isn’t spammed.

## Risks / assumptions
- Assumption: we’re allowed to add a Brave key (or enable Parallel via a dedicated tool) in this deployment.
- Browser automation fallback may be brittle due to dynamic pages/captcha; RSS feeds are preferred where available.

## Links / references
- OpenClaw tool docs (web_search): https://docs.openclaw.ai/tools/web
