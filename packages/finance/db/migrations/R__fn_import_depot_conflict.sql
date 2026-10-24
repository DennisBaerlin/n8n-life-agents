-- ============================================================
-- fn_import_depot_conflict (READ, STABLE) -- widerspricht das gewaehlte Depot einer stock_buy-Zeile den gedruckten
--   Angaben? Genutzt von fn_import_validate_row (Zeilenfehler vor der Karte), fn_import_bundle (erneut beim Commit,
--   kein TOCTOU) und fn_import_resolve_depot (ein widerspruchsfreies extrahiertes Depot bleibt). Kein Widerspruch:
--     - depot_number fehlt bzw. depot_holder fehlt / loest nicht eindeutig auf (weicher Hinweis, nie ein Fehler)
--     - ein Haushalts-Depot (owner_person_id NULL) gegen einen gedruckten Inhaber
--   Widerspruch:
--     - die gedruckte Nummer gehoert einem ANDEREN aktiven Konto (Bestand oder Konto-Zeile dieses Batches)
--     - das gewaehlte Depot hat eine ANDERE gespeicherte Nummer
--     - der gedruckte Inhaber ist eindeutig eine Person, das gewaehlte Depot gehoert einer anderen Person
--   RUECKGABE text (EN, Layer 1) | NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_depot_conflict(p_batch_id uuid, p jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_depot  TEXT := NULLIF(btrim(COALESCE(p->>'depot', '')), '');
    v_num    TEXT := finance.fn_normalize_account_number(p->>'depot_number');
    v_other  TEXT;
    v_stored TEXT;
    v_owner  TEXT;
    v_person TEXT;
    v_full   TEXT;
BEGIN
    IF v_depot IS NULL THEN RETURN NULL; END IF;

    IF v_num IS NOT NULL THEN
        SELECT n INTO v_other FROM (
            SELECT a.name AS n FROM finance.accounts a
            WHERE a.status = 'active' AND a.account_number = v_num
            UNION
            SELECT s.payload->>'name' FROM finance.import_staging s
            WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
              AND finance.fn_normalize_account_number(s.payload->>'account_number') = v_num) t
        WHERE lower(n) <> lower(v_depot)
        LIMIT 1;
        IF v_other IS NOT NULL THEN
            RETURN format('the printed depot number %s belongs to "%s", not to "%s" - set depot to "%s", or remove depot_number if it was misread',
                          v_num, v_other, v_depot, v_other);
        END IF;

        SELECT a.account_number INTO v_stored FROM finance.accounts a
        WHERE a.status = 'active' AND lower(a.name) = lower(v_depot) LIMIT 1;
        IF v_stored IS NULL THEN
            SELECT finance.fn_normalize_account_number(s.payload->>'account_number') INTO v_stored
            FROM finance.import_staging s
            WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
              AND lower(s.payload->>'name') = lower(v_depot) LIMIT 1;
        END IF;
        IF v_stored IS NOT NULL AND v_stored <> v_num THEN
            RETURN format('depot "%s" has account number %s, but the document prints depot number %s - set depot to the depot of this document, or remove depot_number if it was misread',
                          v_depot, v_stored, v_num);
        END IF;
    END IF;

    IF NULLIF(btrim(COALESCE(p->>'depot_holder', '')), '') IS NOT NULL THEN
        SELECT r.person_id, r.full_name INTO v_person, v_full
        FROM core.fn_resolve_person(btrim(p->>'depot_holder')) r WHERE r.hit_count = 1;
        IF v_person IS NOT NULL THEN
            SELECT a.owner_person_id INTO v_owner FROM finance.accounts a
            WHERE a.status = 'active' AND lower(a.name) = lower(v_depot) LIMIT 1;
            IF v_owner IS NOT NULL AND v_owner <> v_person THEN
                RETURN format('depot "%s" belongs to another household member, but the document names %s as the depot holder - set depot to the depot of %s, or remove depot_holder if it was misread',
                              v_depot, v_full, v_full);
            END IF;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
