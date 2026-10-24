-- ============================================================
-- career.fn_skill_level_rank (WS-3 — Ordinal-Rang der Kompetenz-Skala, EINE Quelle der 4 Werte)
--   Bildet die 4-stufige Skala beginner<intermediate<advanced<expert auf einen vergleichbaren Rang ab
--   (beginner=1 .. expert=4), damit die DB "Ist-Level X unter Soll-Level Y" DETERMINISTISCH rechnet
--   (CLAUDE.md "LLM rechnet nicht"). KEIN PG-ENUM (arch-challenge D1: D4-Typ-USAGE-Falle fuer die engen
--   Paket-Rollen + ein ENUM kann ein JSONB-Sub-Feld eh nicht erzwingen) und KEINE Lookup-Tabelle (YAGNI fuer
--   4 geschlossene, bereits validierte Werte). Muster finance.fn_interest_default_convention (IMMUTABLE,
--   hardcoded CASE, keine Tabelle -> markierbar IMMUTABLE).
--
--   RAISE-FREI: unbekanntes/NULL-Level -> 0 (lower(NULL)=NULL -> ELSE). 0 = "unter jedem geforderten Level >=1",
--   d. h. ein nicht erkanntes gespeichertes Level taucht als Luecke auf, statt die all-Advisor-CTE zu killen
--   (career.fn_advisor_review DARF NIE RAISEn).
--
--   SINGLE SOURCE OF TRUTH: die Validatoren (career.fn_validate_career_profile Ist + ..._planning Soll) UND
--   die Gap-fn career.fn_skill_gap delegieren die 4-Werte-Menge an DIESE fn (rank=0 <=> ungueltig) -> die
--   Skala hat genau EINE Definition.
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_skill_level_rank.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_skill_level_rank(p_level text)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE lower(p_level)
        WHEN 'beginner'     THEN 1
        WHEN 'intermediate' THEN 2
        WHEN 'advanced'     THEN 3
        WHEN 'expert'       THEN 4
        ELSE 0
    END::smallint;
$$;
