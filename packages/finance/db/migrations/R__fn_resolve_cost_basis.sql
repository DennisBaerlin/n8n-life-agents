-- ============================================================
-- fn_resolve_cost_basis (READ, IMMUTABLE) -- ist ein genannter Einstand je Stueck oder gesamt gemeint?
--   Eingabe: Wert, Stueck, Referenzkurs (historischer Kurs am Buchungstag, sonst aktueller). Band 0,2 bis 5 wie die
--   grobe Plausi in sub_resolve_yahoo_symbol. Genau eine Lesart plausibel -> uebernehmen. Stueck nahe 1 -> beide
--   Lesarten sind gleich, keine Frage. Beide oder keine plausibel, oder kein Referenzkurs -> kind 'ask'.
--   RUECKGABE: {kind:'total'|'per_share'|'ask', cost_total (NULL bei ask), as_per_share, as_total}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_cost_basis(p_value numeric, p_shares numeric, p_ref numeric)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_unit  BOOLEAN;
    v_total BOOLEAN;
    v_kind  TEXT;
BEGIN
    IF p_value IS NULL OR p_value <= 0 OR p_shares IS NULL OR p_shares <= 0 THEN
        RETURN jsonb_build_object('kind', 'ask', 'cost_total', NULL);
    END IF;
    IF abs(p_shares - 1) < 0.01 THEN
        v_kind := 'total';
    ELSIF p_ref IS NULL OR p_ref <= 0 THEN
        v_kind := 'ask';
    ELSE
        v_unit  := p_value / p_ref BETWEEN 0.2 AND 5;
        v_total := (p_value / p_shares) / p_ref BETWEEN 0.2 AND 5;
        v_kind  := CASE WHEN v_unit AND NOT v_total THEN 'per_share' WHEN v_total AND NOT v_unit THEN 'total' ELSE 'ask' END;
    END IF;
    RETURN jsonb_build_object('kind', v_kind,
        'cost_total', CASE v_kind WHEN 'per_share' THEN round(p_value * p_shares, 2) WHEN 'total' THEN round(p_value, 2) END,
        'as_per_share', round(p_value * p_shares, 2), 'as_total', round(p_value, 2));
END;
$$;
