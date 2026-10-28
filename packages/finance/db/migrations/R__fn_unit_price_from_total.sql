-- ============================================================
-- fn_unit_price_from_total (rein, IMMUTABLE) -- Einstandskurs je Stueck aus dem Gesamt-Einstand
--   Die EINE Rechen-Adresse fuer "Stueck + Gesamtbetrag" einer Bestandsuebernahme (Import: fn_import_normalize_payload,
--   Einzel-Tool: fn_book_stock_buy cost_basis_total) -- das LLM rechnet den Durchschnittskurs nie selbst.
--   8 Nachkommastellen = Spaltenpraezision von transactions.unit_price (Rundungs-Paket 2026-10-23).
--   NULL, wenn Gesamtbetrag oder Stueck fehlen bzw. Stueck <= 0 (der Aufrufer meldet den Fehler).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_unit_price_from_total(p_total numeric, p_shares numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_total IS NOT NULL AND p_shares > 0 THEN round(p_total / p_shares, 8) END;
$$;
