-- ============================================================
-- finance.fn_app_screen_overview(p jsonb) — Mini-App-Bildschirm „Vermögen" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12): core.fn_app_screen ruft ihn mit
--   {person_id, params} NACH der initData-Pruefung. Liefert Struktur + typisierte Werte (core.fn_ui_tpl/_money/_date),
--   nie Text; die Seite rendert per Get-UiRenderLibJs und rechnet nichts (Summen, Anteile, gap kommen von hier).
--   Quellen: networth_by_asset_class (je bucket summiert, has_fx_gap) + accounts/account_balances (cash, Festgeld, P2P;
--   Kredit- und Depot-Konten nicht, deren Wert steht in den Anlagearten bzw. im Bildschirm Kredite/Depot).
--   ZERO-TRUST-SICHTBARKEIT: die Rolle loest der Handler selbst auf (core.fn_household_persons), nie der Aufrufer.
--     Allow-List: owner/partner sehen den Haushalt; jede andere oder unbekannte Rolle nur owner_person_id = ich
--     (Haushaltszeilen mit NULL bleiben fuer Kinder unsichtbar). Die Antwort traegt keine IDs.
--   params.probe = true -> nur {ok, empty} (Navigation zeigt nur nicht-leere Bildschirme).
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (Muster career.fn_read_job_matches); der INVOKER-Bulk-
--   Grant an finance_ro laesst DEFINER-fns aus, EXECUTE bekommt nur finance_rw (Bulk) bzw. der Host als Eigentuemer.
--   Tests: tests/db/finance/test_fn_app_screen_overview.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_overview(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid     text;
    v_hh      boolean;
    v_total   numeric;
    v_gap     boolean;
    v_classes jsonb;
    v_accts   jsonb;
    v_empty   jsonb := core.fn_ui_tpl('finance.app.overview.empty');
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid := p ->> 'person_id';
    SELECT COALESCE(bool_or(hp.role IN ('owner', 'partner')), false) INTO v_hh
      FROM core.fn_household_persons() hp
     WHERE hp.person_id = v_pid;

    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        RETURN jsonb_build_object('ok', true, 'empty', NOT EXISTS (
            SELECT 1 FROM finance.networth_by_asset_class n WHERE v_hh OR n.owner_person_id = v_pid));
    END IF;

    -- Anlagearten: je bucket (feste Reihenfolge), Anteil am Brutto-Vermoegen nur fuer positive Werte
    WITH b AS (
        SELECT n.bucket, sum(n.value_eur) AS val, bool_or(n.has_fx_gap) AS gap
          FROM finance.networth_by_asset_class n
         WHERE v_hh OR n.owner_person_id = v_pid
         GROUP BY n.bucket
    ), g AS (
        SELECT sum(val) FILTER (WHERE val > 0) AS gross, sum(val) AS total, COALESCE(bool_or(gap), false) AS gap FROM b
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', jsonb_build_object('kind', 'enum', 'enum', 'finance.enum.asset_bucket', 'value', b.bucket),
               'sub', NULL,
               'value', core.fn_ui_money(b.val, 'EUR'),
               'gap', b.gap,
               'pill', NULL,
               'progress', CASE WHEN b.val > 0 AND g.gross > 0
                                THEN jsonb_build_object('pct', round(100 * b.val / g.gross, 1), 'state', 'neutral') END,
               'target', NULL)
             ORDER BY array_position(ARRAY['cash', 'fixed_deposit', 'p2p', 'depot', 'real_estate', 'pension', 'loan'],
                                     b.bucket), b.bucket) FILTER (WHERE b.bucket IS NOT NULL), '[]'::jsonb),
           COALESCE(max(g.total), 0),
           COALESCE(bool_or(g.gap), false)
      INTO v_classes, v_total, v_gap
      FROM g LEFT JOIN b ON true;

    -- Konten: Saldo in Kontowaehrung, gap = Saldo ohne Wechselkurs, Datum des letzten bestaetigten Auszugs
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', a.name,
               'sub', CASE WHEN a.last_reconciled_at IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.overview.confirmed_on',
                                               jsonb_build_object('date', core.fn_ui_date(a.last_reconciled_at))) END,
               'value', core.fn_ui_money(ab.balance, a.currency),
               'gap', COALESCE(ab.balance <> 0 AND finance.fn_to_eur(ab.balance, a.currency) IS NULL, false),
               'pill', NULL,
               'progress', NULL,
               'target', NULL)
             ORDER BY finance.fn_to_eur(ab.balance, a.currency) DESC NULLS LAST, a.name), '[]'::jsonb)
      INTO v_accts
      FROM finance.accounts a
      JOIN finance.account_balances ab ON ab.account_id = a.id
     WHERE a.status = 'active'
       AND a.account_type IN ('cash', 'fixed_deposit', 'p2p')
       AND (v_hh OR a.owner_person_id = v_pid);

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.overview.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.overview.hero'),
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', jsonb_build_array(
            jsonb_build_object('title', core.fn_ui_tpl('finance.app.overview.section_classes'),
                               'empty', v_empty, 'items', v_classes),
            jsonb_build_object('title', core.fn_ui_tpl('finance.app.overview.section_accounts'),
                               'empty', v_empty, 'items', v_accts)));
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_overview(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
