-- ============================================================
-- fn_config_eur_in_currency (READ, STABLE) -- EUR-Betrag aus core.config (Kategorie finance) in einer Kontowaehrung
--   Die EINE Adresse der Regel „Euro-Einstellung -> Kontowaehrung“ (vorher je Konsument kopiert):
--   Wert = core.fn_config_get('finance', 'finance', p_key), gelesen ohne Cast-RAISE (fn_parse_numeric_or_null);
--   fehlt/unlesbar/negativ -> p_default; 0 bleibt 0 (z. B. Puffer 0). EUR -> unveraendert. Sonst Wert / EUR-Wert einer
--   Einheit zum Stichtag p_as_of (fn_to_eur_unrounded: juengster Kurs <= Stichtag, sonst juengster ueberhaupt), UNGERUNDET
--   geteilt (1 KRW = 0.00069 EUR wurde mit Cent-Rundung 0.00 -> Betrag still wirkungslos), Ergebnis auf Cent.
--   Ohne Kurs NULL — nie den rohen EUR-Wert; der Konsument entscheidet die Rueckfallebene.
--   Konsumenten: fn_account_outlook (coverage_buffer_eur, ohne Kurs EUR-Wert), fn_statement_prepare (everyday_oneoff_eur,
--   ohne Kurs keine Grenze).
--   Tests: tests/db/finance/test_fn_config_eur_in_currency.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_config_eur_in_currency(p_key text, p_default numeric, p_currency char(3), p_as_of date)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_eur  NUMERIC := finance.fn_parse_numeric_or_null(core.fn_config_get('finance', 'finance', p_key), false);
    v_eur1 NUMERIC;
BEGIN
    IF v_eur IS NULL OR v_eur < 0 THEN v_eur := p_default; END IF;
    IF p_currency = 'EUR' THEN RETURN v_eur; END IF;
    v_eur1 := finance.fn_to_eur_unrounded(1, p_currency, p_as_of);
    RETURN CASE WHEN v_eur1 > 0 THEN round(v_eur / v_eur1, 2) END;
END;
$$;
