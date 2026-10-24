-- ============================================================
-- career.fn_market_scope_key (WS-4 — EINE Quelle des Markt-Cache-Schluessel-Formats)
--   Baut den stabilen scope_key der career.market_signals-Zeilen DETERMINISTISCH in der DB
--   (CLAUDE.md "JS/LLM rechnet nicht abgeleitete Werte"). Genutzt an BEIDEN Enden, damit Write und
--   Read denselben Schluessel treffen (sonst still kein Trend/Gap-Match):
--     * career.fn_upsert_market_signals (Write — der Cron uebergibt ROHE Felder, die DB baut den Key)
--     * career.fn_market_trend          (Read  — rekonstruiert den Key der primaeren Ziel-Rolle)
--   Format: `<kind>:<slug(primary)>:<slug(secondary)>` — generischer Builder; v1 nutzt nur
--     kind='postings' -> primary=Rollen-Titel, secondary=Ort (Jobsuche maxErgebnisse = Posting-Count).
--     (Ein kuenftiges strukturiertes Gehaltsband (BACKLOG Destatis GENESIS) nutzte wieder kind='salary'.)
--   Slug = lower(trim) + Nicht-Alphanumerisches -> "-" (gestrippt am Rand): Scrum Master -> scrum-master,
--   Hamburg -> hamburg. IMMUTABLE (kein Tabellen-Read; Muster fn_skill_level_rank).
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_market_scope_key.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_market_scope_key(p_kind text, p_primary text, p_secondary text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(trim(COALESCE(p_kind, '')))
        || ':' || trim(both '-' from regexp_replace(lower(trim(COALESCE(p_primary,   ''))), '[^a-z0-9]+', '-', 'g'))
        || ':' || trim(both '-' from regexp_replace(lower(trim(COALESCE(p_secondary, ''))), '[^a-z0-9]+', '-', 'g'));
$$;
