-- ============================================================
-- fn_resolve_account (READ, STABLE)
--   Loest Account-Name in ID auf. Liefert Mehrdeutigkeits-Info,
--   damit Helper bei hit_count > 1 dem Nutzer die Treffer praesentieren koennen.
--   Rueckgabe: TABLE(id, hit_count, candidates, currency, label); id nur bei genau einem Treffer.
--   p_types: optional Filter als TEXT[], z. B. ARRAY['stocks_depot','crypto_depot']
--            (intern auf finance.account_type gecastet)
--   p_active_only: wenn TRUE, nur status='active'
--   currency: Kontowaehrung des eindeutigen Treffers (NULL bei 0/>1) — die eine Quelle fuer HITL-Karten, die einen
--   Betrag in der Waehrung des aufgeloesten Kontos zeigen (statt eines Subselects je Tool).
--   label: Anzeigename mit Konto-Zeichen (fn_account_label), auch je Candidate; NULL bei 0/>1. name bleibt die Tool-Eingabe.
--   Namensvergleich: erst exakt, nur bei 0 Treffern ohne Gross-/Kleinschreibung (finance.fn_name_matches); bei weiter 0 Treffern ein
--   fuehrendes Listen-Zeichen abgeschnitten, weil das Modell den fertigen Anzeigenamen uebergeben kann. Nur hier: fn_name_matches
--   bedient alle Objektarten, Nicht-Konten haben keine Zeichen.
-- ============================================================
-- Rueckgabetyp aendert sich mit neuen Spalten: CREATE OR REPLACE allein reicht nicht.
DROP FUNCTION IF EXISTS finance.fn_resolve_account(text, text[], boolean);
CREATE OR REPLACE FUNCTION finance.fn_resolve_account(
    p_name           text,
    p_types          text[]  DEFAULT NULL,
    p_active_only    boolean DEFAULT TRUE
) RETURNS TABLE (
    id          int,
    hit_count   int,
    candidates  jsonb,
    currency    text,
    label       text
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         INT;
    v_ccy        TEXT;
    v_label      TEXT;
    v_pass       INT;
    v_stripped   TEXT := NULLIF(finance.fn_account_name_without_emoji(p_name), '');
BEGIN
    FOR v_pass IN 1..3 LOOP
    EXIT WHEN v_pass = 3 AND v_stripped IS NULL;
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',           a.id,
            'name',         a.name,
            'label',        finance.fn_account_label(a.emoji, a.account_type, a.name),
            'bank',         a.bank,
            'account_type', a.account_type,
            'status',       a.status
        ) ORDER BY a.id),
        COUNT(*),
        MIN(a.id),
        MIN(a.currency),
        MIN(finance.fn_account_label(a.emoji, a.account_type, a.name))
    INTO v_candidates, v_count, v_id, v_ccy, v_label
    FROM finance.accounts a
    WHERE finance.fn_name_matches(a.name, CASE WHEN v_pass = 3 THEN v_stripped ELSE p_name END, v_pass = 1)
      AND (p_types IS NULL OR a.account_type::TEXT = ANY(p_types))
      AND (p_active_only = FALSE OR a.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb),
        CASE WHEN v_count = 1 THEN v_ccy ELSE NULL END,
        CASE WHEN v_count = 1 THEN v_label ELSE NULL END;
END;
$$;
