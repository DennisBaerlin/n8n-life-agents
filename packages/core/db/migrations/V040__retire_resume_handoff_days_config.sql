-- ============================================================
-- V040 (core) — die Config-Zeile advisor.resume_handoff_days entfernen.
--
--   WARUM: core.fn_advisor_resume_due erinnert nicht mehr an die Liste noch offener vereinbarter Eintraege (sie kommt
--   einmal nach dem Veroeffentlichen, danach still im Menue); der Wert steuert nichts mehr. `lifeagents config list` zeigt
--   nur Zeilen, die wirken. Seeds loeschen nie (core.fn_config_seed ist ein Upsert) -> ohne diese Migration bliebe die
--   Bestandszeile als Leiche. Muster V038. Frische DB = no-op.
--
-- APPLY-ORDER: Inits -> V (hier) -> R. Re-run-sicher.
-- ============================================================

DELETE FROM core.config
WHERE package = 'core'
  AND category = 'advisor'
  AND key = 'resume_handoff_days';
