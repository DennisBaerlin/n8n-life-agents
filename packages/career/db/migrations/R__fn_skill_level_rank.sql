-- ============================================================
-- career.fn_skill_level_rank (READ)
--   Ordinal-Rang der Kompetenz-Skala, eine Quelle der 4 Werte: bildet beginner<intermediate<advanced<expert
--   auf einen vergleichbaren Rang ab (beginner=1 .. expert=4), damit die DB "Ist-Level X unter Soll-Level Y"
--   deterministisch rechnet. Eingabe p_level (text, Gross-/Kleinschreibung egal). Rueckgabe smallint 0..4.
--   Kein PG-ENUM (Typ-USAGE-Falle fuer die engen Paket-Rollen; ein ENUM kann ein JSONB-Sub-Feld ohnehin nicht
--   erzwingen) und keine Lookup-Tabelle (4 geschlossene, bereits validierte Werte). Muster
--   finance.fn_interest_default_convention (hardcoded CASE, keine Tabelle -> IMMUTABLE).
--
--   RAISE-frei: unbekanntes/NULL-Level -> 0 (lower(NULL)=NULL -> ELSE). 0 = "unter jedem geforderten Level >=1",
--   d. h. ein nicht erkanntes gespeichertes Level taucht als Luecke auf, statt die all-Advisor-CTE zu killen
--   (career.fn_advisor_review darf nie RAISEn).
--
--   Single Source of Truth: die Validatoren (career.fn_validate_career_profile Ist + ..._planning Soll) und
--   die Gap-fn career.fn_skill_gap delegieren die 4-Werte-Menge an diese fn (rank=0 <=> ungueltig).
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
