-- ============================================================
-- career.fn_market_scope_key (READ)
--   Eine Quelle des Markt-Cache-Schluessel-Formats: baut den stabilen scope_key der career.market_signals-Zeilen
--   deterministisch in der DB. Genutzt an beiden Enden, damit Write und Read denselben Schluessel treffen
--   (sonst still kein Trend/Gap-Match):
--     * career.fn_upsert_market_signals (Write: der Cron uebergibt rohe Felder, die DB baut den Key)
--     * career.fn_market_trend          (Read: rekonstruiert den Key der primaeren Ziel-Rolle)
--   Eingabe: p_kind, p_primary, p_secondary (alle NULL-tolerant, NULL = ''). Format
--   `<kind>:<slug(primary)>:<slug(secondary)>`; aktuell nur kind='postings' -> primary=Rollen-Titel,
--   secondary=Ort (Jobsuche maxErgebnisse = Posting-Count).
--   Rueckgabe: text (kein ok-Objekt). Slug = lower(trim) + Nicht-Alphanumerisches -> "-" (gestrippt am Rand):
--   Data Analyst -> data-analyst, Leipzig -> leipzig. IMMUTABLE (kein Tabellen-Read; Muster fn_skill_level_rank).
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_market_scope_key(p_kind text, p_primary text, p_secondary text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(trim(COALESCE(p_kind, '')))
        || ':' || trim(both '-' from regexp_replace(lower(trim(COALESCE(p_primary,   ''))), '[^a-z0-9]+', '-', 'g'))
        || ':' || trim(both '-' from regexp_replace(lower(trim(COALESCE(p_secondary, ''))), '[^a-z0-9]+', '-', 'g'));
$$;
