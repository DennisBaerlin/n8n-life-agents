-- ============================================================
-- V025 (core) — die tote Config-Zeile feature.prompt_caching entfernen.
--
--   WARUM: `lifeagents config list` zeigt nur noch Zeilen, die auch wirken. feature.prompt_caching schaltete
--   nichts (der Anthropic-Node von n8n 2.21.7 hat keine Caching-Option; der Wiring-Kommentar in New-LmChatNode
--   ist mit entfernt). Kommt die Option, legt der BACKLOG-Punkt den Schalter neu an.
--
--   WARUM eine V-Migration (kein Seed): Seeds sind additiv und loeschen nie (core.fn_config_seed ist ein Upsert);
--   das Manifest deklariert den Key nicht mehr -> die Bestandszeile bliebe sonst als Leiche. Muster V007.
--   Owner-Werte anderer Zeilen bleiben unberuehrt; ungueltige Bestandswerte (seit value_type) setzt der naechste
--   Seed gezielt zurueck (core.fn_config_seed), nicht diese Migration.
--
--   IDEMPOTENT: V laeuft genau einmal (ledger-gegated). Frische DB = no-op.
--   Nummer: V024 ist vom parallelen Gemini->Claude-Umbau belegt; die Reihenfolge der beiden ist egal
--   (core.migration_should_apply reserviert je Version, Luecken sind erlaubt).
--
-- APPLY-ORDER: Inits -> V (hier) -> R. Re-run-sicher.
-- ============================================================

DELETE FROM core.config
WHERE package = 'core'
  AND category = 'feature'
  AND key = 'prompt_caching';
