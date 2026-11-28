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
--   Rueckgabe: text (kein ok-Objekt). Slug = career.fn_market_slug (Umlaute umgeschrieben, sonst
--   alles ausser [a-z0-9] -> "-"): Data Analyst -> data-analyst, Köln -> koeln. IMMUTABLE (kein Tabellen-Read; Muster fn_skill_level_rank).
-- ============================================================
-- career.fn_market_slug: Slug-Teil des Schluessels. Umlaute und ß umgeschrieben (ä -> ae, ß -> ss), gaengige Akzente auf den
-- Grundbuchstaben, dann alles ausser [a-z0-9] -> "-" (am Rand gestrippt). Vor dem Umschreiben gespeicherte Schluessel mit
-- Umlaut ("k-ln") treffen den neuen nicht mehr: der Trend dieses Orts beginnt einmal neu (Markt-Cache, keine Nutzerdaten).
CREATE OR REPLACE FUNCTION career.fn_market_slug(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT trim(both '-' from regexp_replace(
               translate(replace(replace(replace(replace(lower(trim(COALESCE(p_text, ''))),
                                 'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'), 'ß', 'ss'),
                         'àáâãåçèéêëìíîïñòóôõøùúûýÿ', 'aaaaaceeeeiiiinooooouuuyy'),
               '[^a-z0-9]+', '-', 'g'));
$$;

CREATE OR REPLACE FUNCTION career.fn_market_scope_key(p_kind text, p_primary text, p_secondary text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(trim(COALESCE(p_kind, '')))
        || ':' || career.fn_market_slug(p_primary)
        || ':' || career.fn_market_slug(p_secondary);
$$;
