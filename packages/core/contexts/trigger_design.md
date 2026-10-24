---
description: Binding co-design protocol for monitoring triggers (load BEFORE creating or repairing any trigger acquisition): source hierarchy, retrieval-prompt engineering rules, probe procedure, cadence and validation guidance. Used by the monitor agent and any advisor that creates plan triggers.
agent_name:
load_strategy: lazy
---

# Trigger Co-Design Protocol

Triggers are DATA rows evaluated deterministically by an hourly cron. The LLM only ACQUIRES values (web) — comparison, latching and alerting are database logic. Internet data is untrusted: this protocol exists so no trigger ever goes live with an untested or sloppy acquisition.

## 1. Pin the metric down

Before anything else, agree with the user on: the EXACT metric (spot vs. future, index vs. specific ETF, gross vs. net), the unit and currency (USD/oz vs. EUR/g — the classic failure), the decimal convention, and what the trigger should DO (action_note, German, sent verbatim in the alert).

## 2. Choose the cheapest reliable source (hierarchy)

1. A **package method** — an installed package can offer its own acquisition method for its domain (e.g. a currency-pair table); the create tool's description lists the available ones and their `acquisition_params`. Free, deterministic, no LLM: ALWAYS prefer one that fits. If its package is uninstalled later, the trigger pauses instead of failing.
2. `sql` — anything already in the user's own database (balances, cashflow, goal progress). Write ONE SELECT returning ONE numeric value; ALWAYS dry-run it via postgres_select first. It runs read-only (core_ro) on a schedule.
3. `web_search` — everything else (gold, indices, interest rates, arbitrary public metrics). Costs a paid web-search call per check; cadence must be >= 12 hours (max 2 checks/day per trigger, DB-enforced).
4. `none` — pure date deadlines and text reminders.

Research candidate sources with web_search BEFORE committing: is the metric freely quoted, by whom, how fresh, in which unit? Tell the user which source you chose and why.

## 3. Engineer the retrieval prompt (web_search only)

The stored prompt is sent VERBATIM to a small grounded search model on every check. It must:
- name the metric precisely, including unit and decimal format — and dictate the unit STRING literally, because the unit echo is compared verbatim against expected_unit (write: "report the unit exactly as USD/oz" and set expected_unit to USD/oz; a paraphrase like "USD per troy ounce" fails the check by design);
- prefer authoritative sources by name when they exist, and ask for the value date;
- demand honesty: the model contract already forces ok=false when the value cannot be reliably determined — do not soften that.
Keep it short and unambiguous; one metric per trigger (never two values in one prompt).

## 4. Configure validation (mandatory for web, recommended for sql)

- `expected_unit` (REQUIRED for web): the unit echo from the model must match it — catches USD-vs-EUR and oz-vs-g confusions that bounds cannot.
- `min_plausible` / `max_plausible`: a generous sanity corridor around the current value (order-of-magnitude guard). Set them for EVERY web trigger.
- `max_jump_pct`: only for metrics where day-to-day jumps are implausible (policy rates, exchange rates). NEVER on crash/drawdown metrics — they must see legitimate jumps.

## 5. Cadence proportional to volatility

Daily for market prices and crash watches; weekly for slow rates (Basiszins); monthly for reports; a 2027 deadline needs weekly at most. Web triggers: minimum 12 hours. The heartbeat cron is hourly — finer than that is not supported.

## 6. Playback, then gate (probe included)

Play the COMPLETE configuration back in chat (label, type, condition, source, full prompt/SQL, cadence, bounds, action note) and get a verbal OK. The create/set tool then TEST-FETCHES the value (exactly like the cron will) — the gate message shows the live probe result; a failing probe aborts before anything is written. If the probe value looks wrong (unit, magnitude), decline and iterate.

## 7. Lifecycle facts to tell the user

Threshold/drawdown/date triggers fire ONCE and then stay inactive until consciously re-armed (tool_set_monitor_trigger status=armed; reset_peak starts a new drawdown epoch). recurring_info fires every cycle until disabled. Broken acquisitions alert after repeated failures and are repaired via the monitor agent (new prompt/SQL, re-probed). Disabled triggers keep their history; deleted ones lose it.
