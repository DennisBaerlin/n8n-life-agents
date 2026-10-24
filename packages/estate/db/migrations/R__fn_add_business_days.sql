-- ============================================================
-- estate.fn_add_business_days (Fristen-Engine, WS-3 — IMMUTABLE)
--   Addiert p_count WERKTAGE auf p_start (strikt NACH p_start; § 187 BGB: der Ereignistag zaehlt nicht).
--   Werktag = Montag–Freitag, das KEIN gesetzlicher Feiertag des Bundeslands ist. SAMSTAG zaehlt
--   NICHT (§ 28 PStG-Praxis: die Sterbefallanzeige-Frist "dritter Werktag" behandelt Sa wie einen
--   Nicht-Werktag) — bewusst enger als der allgemeine HGB-Werktag. Feiertage aus fn_public_holidays.
--   IMMUTABLE (keine Tabelle gelesen; ruft nur die IMMUTABLE fn_public_holidays). p_count<=0/NULL ->
--   p_start unveraendert. Der Zaehler ist klein (§ 28 PStG: 3) -> die Schleife ist billig.
--   EINGABE: p_start date, p_count int, p_bundesland text. RUECKGABE: date.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_add_business_days.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_add_business_days(p_start date, p_count int, p_bundesland text)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_d     DATE := p_start;
    v_added INT  := 0;
BEGIN
    IF p_start IS NULL THEN RETURN NULL; END IF;
    IF p_count IS NULL OR p_count <= 0 THEN RETURN p_start; END IF;
    WHILE v_added < p_count LOOP
        v_d := v_d + 1;
        IF EXTRACT(isodow FROM v_d)::int < 6   -- Mo(1)..Fr(5); Sa(6)/So(7) zaehlen nicht
           AND NOT (v_d = ANY (estate.fn_public_holidays(EXTRACT(year FROM v_d)::int, p_bundesland))) THEN
            v_added := v_added + 1;
        END IF;
    END LOOP;
    RETURN v_d;
END;
$$;
