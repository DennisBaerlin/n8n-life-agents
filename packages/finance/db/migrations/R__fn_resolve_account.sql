-- ============================================================
-- fn_resolve_account
--   Loest Account-Name in ID auf. Liefert Mehrdeutigkeits-Info,
--   damit Helper bei hit_count > 1 dem Nutzer die Treffer praesentieren koennen.
--   p_types: optional Filter als TEXT[], z. B. ARRAY['stocks_depot','crypto_depot']
--            (intern auf finance.account_type gecastet)
--   p_active_only: wenn TRUE, nur status='active'
--   currency: Kontowaehrung des eindeutigen Treffers (NULL bei 0/>1) — die EINE Quelle fuer HITL-Karten, die einen
--   Betrag in der Waehrung des aufgeloesten Kontos zeigen (statt eines Subselects je Tool).
--   Namensvergleich: erst exakt, nur bei 0 Treffern ohne Gross-/Kleinschreibung (finance.fn_name_matches).
-- ============================================================
-- RETURNS TABLE um currency erweitert -> Rueckgabetyp aendert sich, CREATE OR REPLACE allein reicht nicht.
DROP FUNCTION IF EXISTS finance.fn_resolve_account(text, text[], boolean);
CREATE OR REPLACE FUNCTION finance.fn_resolve_account(
    p_name           text,
    p_types          text[]  DEFAULT NULL,
    p_active_only    boolean DEFAULT TRUE
) RETURNS TABLE (
    id          int,
    hit_count   int,
    candidates  jsonb,
    currency    text
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         INT;
    v_ccy        TEXT;
    v_exact      BOOLEAN;
BEGIN
    FOREACH v_exact IN ARRAY ARRAY[TRUE, FALSE] LOOP
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',           a.id,
            'name',         a.name,
            'bank',         a.bank,
            'account_type', a.account_type,
            'status',       a.status
        ) ORDER BY a.id),
        COUNT(*),
        MIN(a.id),
        MIN(a.currency)
    INTO v_candidates, v_count, v_id, v_ccy
    FROM finance.accounts a
    WHERE finance.fn_name_matches(a.name, p_name, v_exact)
      AND (p_types IS NULL OR a.account_type::TEXT = ANY(p_types))
      AND (p_active_only = FALSE OR a.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb),
        CASE WHEN v_count = 1 THEN v_ccy ELSE NULL END;
END;
$$;
