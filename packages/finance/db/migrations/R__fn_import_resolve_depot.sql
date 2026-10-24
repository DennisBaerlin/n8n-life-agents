-- ============================================================
-- fn_import_resolve_depot (READ, STABLE) -- Depot einer stock_buy-Import-Zeile aus GEDRUCKTEN Angaben bestimmen
--   Owner-Befund 2026-10-23: die Vision-Extraktion riet den Depot-Namen und ordnete die Positionen einer
--   Vermoegensuebersicht eines Haushaltsmitglieds dem Depot des Owners zu, obwohl Depotnummer und Inhaberin gedruckt waren.
--   Reihenfolge (deterministisch, kein LLM):
--     1. depot_number (normalisiert, fn_normalize_account_number) = Kontonummer GENAU EINES aktiven Depots passenden
--        Typs (ISIN -> stocks_depot, nur Symbol -> crypto_depot, weder noch = Cash-Zeile -> jeder) im Bestand oder einer Konto-Zeile dieses Batches
--        -> dieses Depot (die Nummer ist eine Identitaet, sie schlaegt jeden Namen)
--     2. das extrahierte Depot existiert (Bestand oder Batch, passender Typ) und widerspricht den gedruckten
--        Angaben nicht (fn_import_depot_conflict) -> bleibt (auch ein Haushalts-Depot oder ein neues Batch-Depot)
--     3. depot_holder (gedruckter Inhaber, weicher Hinweis) -> core.fn_resolve_person genau 1 Person -> genau EIN
--        aktives Depot passenden Typs dieser Person im Bestand, dessen gespeicherte Nummer fehlt oder zur gedruckten
--        passt (ein Depot mit anderer Nummer waere sofort ein Widerspruch)
--     4. sonst NULL (der extrahierte bzw. vom Nutzer genannte Name bleibt)
--   Nur fn_import_stage ruft sie (beim Einlesen), nie fn_import_update_row: eine Depot-Korrektur des Nutzers wird
--   nicht still zurueckgedreht. Widersprueche meldet fn_import_depot_conflict als Zeilenfehler.
--   RUECKGABE jsonb {depot, source: number|holder} | NULL (= Name bleibt).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_resolve_depot(p_batch_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    -- Depot-Typ aus der Zeile: ISIN -> stocks_depot, nur Symbol -> crypto_depot, weder noch (Cash-/Saldo-Zeile einer
    -- Depot-Uebersicht, fn_import_balance_targets) -> jeder Depot-Typ
    v_types  TEXT[] := CASE WHEN NULLIF(btrim(COALESCE(p->>'isin', '')), '') IS NOT NULL THEN ARRAY['stocks_depot']
                            WHEN NULLIF(btrim(COALESCE(p->>'symbol', '')), '') IS NOT NULL THEN ARRAY['crypto_depot']
                            ELSE ARRAY['stocks_depot', 'crypto_depot'] END;
    v_num    TEXT := finance.fn_normalize_account_number(p->>'depot_number');
    v_depot  TEXT := NULLIF(btrim(COALESCE(p->>'depot', '')), '');
    v_names  TEXT[];
    v_person TEXT;
BEGIN
    IF v_num IS NOT NULL THEN
        SELECT array_agg(DISTINCT n) INTO v_names FROM (
            SELECT a.name AS n FROM finance.accounts a
            WHERE a.status = 'active' AND a.account_type::text = ANY (v_types) AND a.account_number = v_num
            UNION
            SELECT s.payload->>'name' FROM finance.import_staging s
            WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
              AND s.payload->>'account_type' = ANY (v_types)
              AND finance.fn_normalize_account_number(s.payload->>'account_number') = v_num) t;
        IF cardinality(v_names) = 1 THEN
            RETURN jsonb_build_object('depot', v_names[1], 'source', 'number');
        END IF;
    END IF;

    IF v_depot IS NOT NULL AND finance.fn_import_ref_account_type(p_batch_id, v_depot) = ANY (v_types)
       AND finance.fn_import_depot_conflict(p_batch_id, p) IS NULL THEN
        RETURN NULL;
    END IF;

    IF NULLIF(btrim(COALESCE(p->>'depot_holder', '')), '') IS NOT NULL THEN
        SELECT r.person_id INTO v_person FROM core.fn_resolve_person(btrim(p->>'depot_holder')) r WHERE r.hit_count = 1;
        IF v_person IS NOT NULL THEN
            SELECT array_agg(a.name) INTO v_names FROM finance.accounts a
            WHERE a.status = 'active' AND a.account_type::text = ANY (v_types) AND a.owner_person_id = v_person
              AND (v_num IS NULL OR a.account_number IS NULL OR a.account_number = v_num);
            IF cardinality(v_names) = 1 THEN
                RETURN jsonb_build_object('depot', v_names[1], 'source', 'holder');
            END IF;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
