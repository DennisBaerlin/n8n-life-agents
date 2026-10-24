-- ============================================================
-- fn_import_depot_currency (READ HELPER) -- Waehrung des Depots einer Import-Positionszeile (Review 2026-10-22)
--   tool_commit_import loest VOR der Karte je Position das Yahoo-Listing in der Depot-Waehrung auf. Vorher: Vergleich
--   nur gegen BESTEHENDE Konten, Fallback EUR -> ein im selben Batch angelegtes USD-Depot bekam still ein EUR-Listing.
--   Jetzt dieselbe Aufloesung wie fn_import_bundle/fn_import_resolve_account: (1) Konto-Zeile DIESES Batches
--   (case-insensitiv) mit ihrer Waehrung, sonst der Waehrung ihres Verrechnungskontos (Batch-Zeile oder bestehendes
--   Konto; wie fn_create_account), (2) sonst ein bestehendes Konto (fn_resolve_account: exakter Name, nur eindeutige
--   Treffer), (3) sonst EUR (ein unaufloesbares Depot meldet ohnehin der Probelauf).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_depot_currency(p_batch uuid, p_depot text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_row jsonb;
    v_ccy text;
BEGIN
    SELECT s.payload INTO v_row FROM finance.import_staging s
    WHERE s.batch_id = p_batch AND s.entity_type = 'account' AND lower(s.payload->>'name') = lower(p_depot)
    ORDER BY s.row_no LIMIT 1;
    IF v_row IS NULL THEN
        SELECT r.currency INTO v_ccy FROM finance.fn_resolve_account(p_depot, NULL, TRUE) r;
        RETURN COALESCE(v_ccy, 'EUR');
    END IF;
    v_ccy := finance.fn_normalize_currency(NULLIF(v_row->>'currency', ''));
    IF v_ccy IS NULL AND NULLIF(v_row->>'settlement_account', '') IS NOT NULL THEN
        -- Verrechnungskonto: Batch-Zeile ZUERST (wie das Bundle) — ihre fehlende Waehrung heisst EUR und faellt NICHT
        -- auf ein gleichnamiges Bestandskonto durch.
        SELECT s.payload INTO v_row FROM finance.import_staging s
        WHERE s.batch_id = p_batch AND s.entity_type = 'account'
          AND lower(s.payload->>'name') = lower(v_row->>'settlement_account')
        ORDER BY s.row_no LIMIT 1;
        IF FOUND THEN
            v_ccy := finance.fn_normalize_currency(NULLIF(v_row->>'currency', ''));
        ELSE
            SELECT r.currency INTO v_ccy FROM finance.fn_resolve_account(v_row->>'settlement_account', NULL, TRUE) r;
        END IF;
    END IF;
    RETURN COALESCE(v_ccy, 'EUR');
END;
$$;
