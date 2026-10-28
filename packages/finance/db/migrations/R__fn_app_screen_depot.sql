-- ============================================================
-- finance.fn_app_screen_depot(p jsonb) — Mini-App-Bildschirm „Depot" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Muster finance.fn_app_screen_overview.
--   Quellen: depot_holdings_overview (Marktwert, Kurs-Datum, price_status ok|stale|missing), depot_reserve_status
--   (fuer Ziele reserviert vs. Marktwert), savings_goal_account_share.has_fx_gap. Die Seite rechnet nichts.
--   Hero = Summe market_value_eur der sichtbaren Positionen; gap, wenn eine Position keinen Kurs oder keinen Wechselkurs
--   hat (ein fehlender Kurs faellt nie still als 0 aus). Ein Abschnitt je Depot (Wert absteigend, ohne Wert zuletzt),
--   Positionen nach Wert; Wert in der Kurs-Waehrung (price_currency). Stueckzahl mit den Nachkommastellen, die sie hat.
--   „Fuer Ziele reserviert": gedeckt / nicht gedeckt / nicht ermittelbar. Unbekannt (kein Kurs fuer alle oder einzelne
--   Positionen, Ziel-Anteil ohne Wechselkurs) ist nie gruen. Keine Zielnamen: ein Kind sieht auf dem EIGENEN Depot nur
--   den Betrag (bewusst, auch fuer Haushaltsziele). Die Deckungsluecke ist KEIN Banner: der Berater unterdrueckt sie,
--   wenn das Ziel im Plan ist (fn_advisor_review), ein zweiter Alarm wuerde davon abweichen.
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alle aktiven Depots, alle anderen nur
--     Depots mit owner_person_id = ich.
--   params.probe = true -> {ok, empty, banners}: je Depot mit Kurs veraltet/fehlt ein warn-Banner, target = depot.
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request. Keine IDs in der Antwort.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (EXECUTE nur finance_rw/Host, nie *_ro).
--   Tests: tests/db/finance/test_fn_app_screen_depot.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_depot(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid      text;
    v_hh       boolean;
    v_depots   jsonb;
    v_total    numeric;
    v_gap      boolean;
    v_banners  jsonb;
    v_reserved jsonb;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid := p ->> 'person_id';
    v_hh  := core.fn_app_sees_household(v_pid);

    -- je sichtbarem Depot: Positionen, Wert, Luecke, Kurs-Problem
    WITH d AS (
        SELECT a.id, a.name
          FROM finance.accounts a
         WHERE a.status = 'active' AND a.account_type IN ('stocks_depot', 'crypto_depot')
           AND (v_hh OR a.owner_person_id = v_pid)
    ), per AS (
        SELECT d.name,
               sum(h.market_value_eur) AS val,
               bool_or(h.market_value_eur IS NULL) AS gap,
               bool_or(h.price_status IN ('stale', 'missing')) AS price_issue,
               jsonb_agg(jsonb_build_object(
                   'label', h.name,
                   'sub', CASE WHEN h.price_as_of IS NOT NULL
                               THEN core.fn_ui_tpl('finance.app.depot.shares_price', jsonb_build_object(
                                        'shares', core.fn_ui_num(h.shares, scale(trim_scale(h.shares))),
                                        'date', core.fn_ui_date(h.price_as_of)))
                               ELSE core.fn_ui_tpl('finance.app.depot.shares', jsonb_build_object(
                                        'shares', core.fn_ui_num(h.shares, scale(trim_scale(h.shares))))) END,
                   'value', CASE WHEN h.market_value IS NOT NULL THEN core.fn_ui_money(h.market_value, h.price_currency) END,
                   'gap', h.market_value_eur IS NULL,
                   'pill', CASE h.price_status
                               WHEN 'stale' THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                                                     'text', core.fn_ui_tpl('finance.app.depot.price_stale'))
                               WHEN 'missing' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                                     'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
                           END,
                   'progress', NULL,
                   'target', NULL)
                 ORDER BY h.market_value_eur DESC NULLS LAST, h.name) AS items
          FROM d
          JOIN finance.depot_holdings_overview h ON h.account_id = d.id
         GROUP BY d.id, d.name
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'title', core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', per.name)),
               'empty', core.fn_ui_tpl('finance.app.depot.empty'),
               'items', per.items)
             ORDER BY per.val DESC NULLS LAST, per.name), '[]'::jsonb),
           COALESCE(sum(per.val), 0),
           COALESCE(bool_or(per.gap), false),
           COALESCE(jsonb_agg(jsonb_build_object(
               'state', 'warn', 'icon', 'clock',
               'text', core.fn_ui_tpl('finance.app.depot.banner_price', jsonb_build_object('depot', per.name)),
               'target', jsonb_build_object('screen', 'depot', 'params', '{}'::jsonb))
             ORDER BY per.name) FILTER (WHERE per.price_issue), '[]'::jsonb)
      INTO v_depots, v_total, v_gap, v_banners
      FROM per;

    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        RETURN jsonb_build_object('ok', true, 'empty', jsonb_array_length(v_depots) = 0, 'banners', v_banners);
    END IF;

    -- Fuer Ziele reserviert: unbekannte Deckung (Teil-Summe ohne Kurs, Anteil ohne Wechselkurs) nie gruen
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', r.account_name,
               'sub', NULL,
               'value', core.fn_ui_money(r.reserved, 'EUR'),
               'gap', u.unknown,
               'pill', CASE WHEN u.unknown
                            THEN jsonb_build_object('state', 'neutral', 'icon', 'info',
                                     'text', core.fn_ui_tpl('finance.app.depot.reserve_unknown'))
                            WHEN r.breach
                            THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                     'text', core.fn_ui_tpl('finance.app.depot.reserve_short'))
                            ELSE jsonb_build_object('state', 'ok', 'icon', 'check',
                                     'text', core.fn_ui_tpl('finance.app.depot.reserve_covered')) END,
               'progress', NULL,
               'target', NULL)
             ORDER BY r.account_name), '[]'::jsonb)
      INTO v_reserved
      FROM finance.depot_reserve_status r
      JOIN finance.accounts a ON a.id = r.account_id
      CROSS JOIN LATERAL (
          SELECT EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                          WHERE s.account_id = r.account_id AND s.goal_status = 'active' AND s.has_fx_gap) AS share_gap
      ) sg
      CROSS JOIN LATERAL (
          SELECT r.fx_missing OR sg.share_gap
                 OR EXISTS (SELECT 1 FROM finance.depot_holdings_overview o
                             WHERE o.account_id = r.account_id AND o.market_value_eur IS NULL) AS unknown
      ) u
     WHERE (v_hh OR a.owner_person_id = v_pid)
       AND (r.reserved > 0 OR sg.share_gap);

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.depot.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.depot.hero'),
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', CASE WHEN jsonb_array_length(v_reserved) > 0
                         THEN v_depots || jsonb_build_object(
                                  'title', core.fn_ui_tpl('finance.app.depot.section_reserved'),
                                  'empty', core.fn_ui_tpl('finance.app.depot.empty'),
                                  'items', v_reserved)
                         ELSE v_depots END);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_depot(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
