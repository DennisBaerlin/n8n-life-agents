-- ============================================================
-- fn_depot_cover_state (READ-ONLY Helfer, Mini-App UX 2026-10-30) — deckt der Marktwert eines Depots das Ziel-Geld darin?
--   Die EINE Regel fuer die Depot-Deckung: Mini-App (Ziele, Pille an der Sparziel-Zeile) und Berater-Alert reserve_coverage_depot
--   (fn_advisor_review) lesen beide hier. Der Ziel-Stand bleibt das Gesparte (Marktwert = Deckung, nie Reserve,
--   finance:V008); eine kleine Kursdelle ist keine Luecke (Owner 2026-10-30: „11 EUR ist nicht schlimm, bei heftigen
--   Kursschwankungen gelb").
--   RUECKGABE {state, gap, reserved, market_value}:
--     unknown = Marktwert nicht ermittelbar: depot_reserve_status.fx_missing, eine Position ohne Marktwert
--               (depot_holdings_overview.market_value_eur NULL) oder ein aktiver Ziel-Anteil ohne Wechselkurs
--               (savings_goal_account_share.has_fx_gap) -> nie gruen, gap NULL
--     dip     = Marktwert < Reserve, Fehlbetrag < finance.depot_cover_warn_pct % der Reserve (Kursdelle)
--     short   = Fehlbetrag ab dieser Schwelle (echte Luecke)
--     ok      = gedeckt oder keine Reserve (gap 0)
--   gap = depot_reserve_status.shortfall (EUR). Schwelle zur Laufzeit per core.fn_config_get (Default 10).
--   LANGUAGE plpgsql STABLE, SECURITY INVOKER: nur aus DEFINER-Handlern (fn_app_screen_goals) und fn_advisor_review
--     gerufen; kein eigener Rollen-Vertrag.
--   Tests: tests/db/finance/test_fn_depot_cover_state.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_depot_cover_state(p_account_id int)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    r       record;
    v_pct   numeric;
    v_unk   boolean;
BEGIN
    SELECT s.reserved, s.market_value, s.shortfall, s.breach, s.fx_missing
      INTO r
      FROM finance.depot_reserve_status s
     WHERE s.account_id = p_account_id;

    -- ohne Ziel-Geld im Depot gibt es nichts zu decken: eine Position ohne Kurs macht es dann nicht „unbekannt"
    v_unk := COALESCE(r.fx_missing, false)
             OR (COALESCE(r.reserved, 0) > 0 AND EXISTS (SELECT 1 FROM finance.depot_holdings_overview o
                         WHERE o.account_id = p_account_id AND o.market_value_eur IS NULL))
             OR EXISTS (SELECT 1 FROM finance.savings_goal_account_share sh
                         WHERE sh.account_id = p_account_id AND sh.goal_status = 'active' AND sh.has_fx_gap);
    IF v_unk THEN
        RETURN jsonb_build_object('state', 'unknown', 'gap', NULL, 'reserved', r.reserved, 'market_value', r.market_value);
    END IF;
    IF NOT COALESCE(r.breach, false) THEN
        RETURN jsonb_build_object('state', 'ok', 'gap', 0, 'reserved', COALESCE(r.reserved, 0), 'market_value', r.market_value);
    END IF;

    v_pct := COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'depot_cover_warn_pct'), '')::numeric, 10);
    RETURN jsonb_build_object(
        'state', CASE WHEN r.shortfall < r.reserved * v_pct / 100 THEN 'dip' ELSE 'short' END,
        'gap', r.shortfall, 'reserved', r.reserved, 'market_value', r.market_value);
END;
$$;
