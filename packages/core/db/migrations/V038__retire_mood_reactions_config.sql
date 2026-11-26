-- ============================================================
-- V038 (core) — die tote Config-Zeile persona.mood_reactions_per_day entfernen.
--
--   WARUM: agent.fn_claim_reaction kennt die Art mood (Stimmung neben einer Antwort) nicht; ihre Tages-Obergrenze
--   zaehlt nichts. `lifeagents config list` zeigt nur Zeilen, die wirken.
--   Seeds loeschen nie (core.fn_config_seed ist ein Upsert) -> ohne diese Migration bliebe die Bestandszeile als Leiche.
--   Muster V025. Frische DB = no-op.
--
-- APPLY-ORDER: Inits -> V (hier) -> R. Re-run-sicher.
-- ============================================================

DELETE FROM core.config
WHERE package = 'core'
  AND category = 'persona'
  AND key = 'mood_reactions_per_day';
