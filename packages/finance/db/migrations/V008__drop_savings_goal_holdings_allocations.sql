-- ============================================================
-- V008 (finance) — Phase S WS-B: die beiden alten Depot-Reserve-/Earmark-Tabellen entfernen.
--
--   * savings_goal_holdings (WS-A.2): "ganzer-Bestand-Marktwert je Position einem Ziel zugeordnet" —
--     DOPPELZAEHLT, sobald derselbe ISIN mehreren Zielen dient oder schon vor dem Ziel Anteile bestanden
--     (finance_depot_holdings_isin_uq = ein Bestand je Wertpapier), und laesst einen Bestand nicht per
--     €-Betrag teilen (Owner-Kernwunsch). Abgeloest durch das append-only savings_goal_reserve_entries-Journal
--     (stabiler €-Betrag je Ziel, derived -> driftfrei; Marktwert = Deckung, nicht Reserve).
--   * savings_goal_allocations: die Earmark/FIRE-Topf-Netting-Idee (single-mutable-amount). Das FIRE-Topf-
--     Netting ist bewusst nach BACKLOG verschoben (Reserve-Fundament zuerst, Owner-Entscheid 2026-06-25) ->
--     die Tabelle hat keinen Konsumenten mehr (networth-Earmark-CTE + fn_advisor-Block-(b) sind im selben
--     Commit entfernt).
--
--   SICHER / 0-Row-Vorbedingung: KEIN Schreib-Tool hat je in diese Tabellen geschrieben (es gab keines) ->
--     0 Zeilen by construction; der DROP verliert keine Nutzerdaten. Das ephemere Dev/Test-Substrat traegt
--     sie nach dem Init-Umbau gar nicht mehr (CREATE entfernt) -> DROP IF EXISTS dort no-op.
--
--   CASCADE ist PFLICHT: die V__-Migrationen laufen VOR den R__-View-Repeatables (Treiber-Reihenfolge) ->
--     beim Re-Apply auf einer Bestands-DB referenzieren die NOCH alten Views (networth_by_asset_class ->
--     savings_goal_allocations, savings_goal_progress -> savings_goal_holdings) die Tabellen noch. CASCADE
--     droppt diese Views mit; R__finance_views legt sie unmittelbar danach in der neuen (referenz-freien)
--     Fassung wieder an. Funktions-Koerper (fn_advisor_review) sind keine harten View-Deps -> nicht betroffen.
--
--   IDEMPOTENT: gated ueber core.migration_should_apply (genau einmal je DB); kein BEGIN/COMMIT (der
--   db_apply/apply_schema-Treiber wrapt).
-- ============================================================

DROP TABLE IF EXISTS finance.savings_goal_holdings CASCADE;
DROP TABLE IF EXISTS finance.savings_goal_allocations CASCADE;
