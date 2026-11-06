-- ============================================================
-- fn_import_depot_number_to_store (READ, STABLE) -- gedruckte Depotnummer, die der Commit am Depot nachtraegt
--   Owner 2026-10-23: ein per Chat angelegtes Depot kennt seine Nummer nicht -> der naechste Import speichert sie mit,
--   danach ordnet fn_import_resolve_depot kuenftige Auszuege per Nummer zu. Nur fuer ein BESTANDS-Depot ohne
--   Nummer (ein Depot aus einer Konto-Zeile desselben Batches traegt seine Nummer in dieser Zeile). EINE Bedingung
--   fuer fn_import_card_rows (Kartenzeile mit Depot + Nummer) und fn_import_bundle (Write per fn_set_account im
--   selben Savepoint).
--   RUECKGABE text (normalisierte Nummer) | NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_depot_number_to_store(p_batch_id uuid, p jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_num   TEXT := finance.fn_normalize_account_number(p->>'depot_number');
    v_depot TEXT := NULLIF(btrim(COALESCE(p->>'depot', '')), '');
BEGIN
    IF v_num IS NULL OR v_depot IS NULL THEN RETURN NULL; END IF;
    IF EXISTS (SELECT 1 FROM finance.import_staging s
               WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
                 AND lower(s.payload->>'name') = lower(v_depot)) THEN
        RETURN NULL;
    END IF;
    IF EXISTS (SELECT 1 FROM finance.accounts a
               WHERE a.status = 'active' AND lower(a.name) = lower(v_depot)
                 AND a.account_type IN ('stocks_depot', 'crypto_depot') AND a.account_number IS NULL) THEN
        RETURN v_num;
    END IF;
    RETURN NULL;
END;
$$;
