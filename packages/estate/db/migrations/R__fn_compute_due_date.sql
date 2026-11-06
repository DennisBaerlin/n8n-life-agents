-- ============================================================
-- estate.fn_compute_due_date (Fristen-Engine, WS-3 — IMMUTABLE, DIE zentrale Frist-Berechnung)
--   Rechnet die Faelligkeit einer Task aus Anker-Datum + Frist. Das LLM rechnet NIE — hier lebt die
--   Korrektheit. p_anchor = event_date ODER knowledge_date (der Aufrufer waehlt nach template.
--   deadline_anchor; § 1944 BGB / § 30 ErbStG laufen ab KENNTNIS). Einheiten:
--     * NULL count       -> 'unverzueglich' = am Anker-Tag faellig (RETURN p_anchor).
--     * 'business_day'    -> § 28 PStG-Werktage (fn_add_business_days; Sa/So/Feiertage zaehlen nicht).
--     * 'day'            -> Kalendertage.
--     * 'week'           -> p_count * 7 Kalendertage.
--     * 'month'          -> KALENDARISCH (§§ 187/188 BGB): der Tag GLEICHER ZAHL im Zielmonat; fehlt er
--                          (31. -> kurzer Monat), der letzte Tag des Monats. Genau das leistet die
--                          Postgres-Intervall-Addition (make_interval(months=>n) klemmt auf Monatsende).
--   v1 OHNE § 193-Verschiebung (Frist-Ende an Sa/So/Feiertag wird NICHT auf den naechsten Werktag
--   geschoben) — bewusst konservativ (fruehere Frist), im Plan dokumentiert.
--   p_anchor NULL -> NULL. EINGABE: p_anchor date, p_count int, p_unit text, p_bundesland text.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_compute_due_date.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_compute_due_date(p_anchor date, p_count int, p_unit text, p_bundesland text)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_anchor IS NULL THEN RETURN NULL; END IF;
    IF p_count IS NULL THEN RETURN p_anchor; END IF;   -- 'unverzueglich'
    RETURN CASE p_unit
        WHEN 'business_day' THEN estate.fn_add_business_days(p_anchor, p_count, p_bundesland)
        WHEN 'day'          THEN p_anchor + p_count
        WHEN 'week'         THEN p_anchor + (p_count * 7)
        WHEN 'month'        THEN (p_anchor + make_interval(months => p_count))::date
        ELSE p_anchor
    END;
END;
$$;
