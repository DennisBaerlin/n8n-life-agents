-- ============================================================
-- finance.fn_app_screen_overview(p jsonb) — Mini-App-Bildschirm „Vermögen" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12): core.fn_app_screen ruft ihn mit
--   {person_id, params} NACH der initData-Pruefung. Liefert Struktur + typisierte Werte (core.fn_ui_tpl/_money/_date),
--   nie Text; die Seite rendert per Get-UiRenderLibJs und rechnet nichts (Summen, Anteile, gap kommen von hier).
--   Quellen: networth_by_asset_class (je bucket summiert, has_fx_gap) + accounts/account_balances (cash, Festgeld, P2P;
--   Kredit- und Depot-Konten nicht, deren Wert steht in den Anlagearten bzw. im Bildschirm Kredite/Depot).
--   ZERO-TRUST-SICHTBARKEIT: die Rolle loest der Handler selbst auf (core.fn_app_sees_household), nie der Aufrufer.
--     Allow-List: owner/partner sehen den Haushalt; jede andere oder unbekannte Rolle nur owner_person_id = ich
--     (Haushaltszeilen mit NULL bleiben fuer Kinder unsichtbar). Die Antwort traegt keine IDs.
--   KINDER (Uebersicht R3, Owner 2026-10-28): fuer Haushalts-Betrachter zaehlen Zeilen eines Kindes (role = 'child' via
--     core.fn_household_persons, T2-Muster wie fn_advisor_review) NICHT in Hero/Besitz/Schulden/Konten, sondern stehen im
--     Abschnitt „Kinder" (je Kind Netto, aufklappbar je Anlageart aus DERSELBEN Quelle -> die Details ergeben die Summe).
--     Ein Kind (oder jede andere Rolle) sieht wie bisher nur Eigenes; der Hero heisst dann „Mein Vermoegen".
--   Schulden = Kredite (immer, auch bei 0 oder ohne Kurs) + jede negative Anlageart (ueberzogenes Konto), Besitz = der
--     Rest -> Besitz + Schulden = Netto (Hero). Anteils-Balken = Anteil am Besitz. „Kredite" fuehrt zum Bildschirm Kredite.
--   Konten: Untertitel mit Besitzer (Name bzw. „Gemeinsam") nur fuer Haushalts-Betrachter.
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
    v_pid      text;
    v_hh       boolean;
    v_total    numeric;
    v_assets   numeric;
    v_debts    numeric;
    v_gap      boolean;
    v_classes  jsonb;
    v_debt_it  jsonb;
    v_kids     jsonb;
    v_accts    jsonb;
    v_sections jsonb;
    v_empty    jsonb := core.fn_ui_tpl('finance.app.overview.empty');
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid := p ->> 'person_id';
    v_hh  := core.fn_app_sees_household(v_pid);

    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        RETURN jsonb_build_object('ok', true, 'empty', NOT EXISTS (
            SELECT 1 FROM finance.networth_by_asset_class n WHERE v_hh OR n.owner_person_id = v_pid));
    END IF;

    -- Anlagearten ohne Kinder: je bucket (feste Reihenfolge). Schulden = Kredite (immer, auch bei 0 oder ohne Kurs) und
    -- jede negative Anlageart (ueberzogenes Konto); Besitz = der Rest.
    WITH b AS (
        SELECT n.bucket, sum(n.value_eur) AS val, bool_or(n.has_fx_gap) AS gap,
               (n.bucket = 'loan' OR COALESCE(sum(n.value_eur), 0) < 0) AS is_debt
          FROM finance.networth_by_asset_class n
          LEFT JOIN core.fn_household_persons() hp ON hp.person_id = n.owner_person_id
         WHERE (v_hh AND hp.role IS DISTINCT FROM 'child') OR (NOT v_hh AND n.owner_person_id = v_pid)
         GROUP BY n.bucket
    ), g AS (
        SELECT COALESCE(sum(val) FILTER (WHERE NOT is_debt), 0) AS assets,
               COALESCE(sum(val) FILTER (WHERE is_debt), 0) AS debts,
               COALESCE(sum(val), 0) AS total, COALESCE(bool_or(gap), false) AS gap FROM b
    ), ord AS (
        SELECT b.*, array_position(ARRAY['cash', 'fixed_deposit', 'p2p', 'depot', 'real_estate', 'pension', 'loan'],
                                   b.bucket) AS o
          FROM b
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', jsonb_build_object('kind', 'enum', 'enum', 'finance.enum.asset_bucket', 'value', ord.bucket),
               'sub', CASE WHEN ord.val > 0 AND g.assets > 0
                           THEN core.fn_ui_tpl('finance.app.overview.share', jsonb_build_object(
                                    'pct', core.fn_ui_num(round(100 * ord.val / g.assets, 1), 1))) END,
               'value', core.fn_ui_money(ord.val, 'EUR'),
               'gap', ord.gap,
               'pill', NULL,
               'progress', CASE WHEN ord.val > 0 AND g.assets > 0
                                THEN jsonb_build_object('pct', round(100 * ord.val / g.assets, 1), 'state', 'neutral') END,
               'target', NULL)
             ORDER BY ord.o, ord.bucket) FILTER (WHERE ord.bucket IS NOT NULL AND NOT ord.is_debt),
             '[]'::jsonb),
           COALESCE(jsonb_agg(jsonb_build_object(
               'label', jsonb_build_object('kind', 'enum', 'enum', 'finance.enum.asset_bucket', 'value', ord.bucket),
               'sub', NULL,
               'value', core.fn_ui_money(ord.val, 'EUR'),
               'gap', ord.gap,
               'pill', NULL,
               'progress', NULL,
               'target', CASE WHEN ord.bucket = 'loan'
                              THEN jsonb_build_object('screen', 'loans', 'params', '{}'::jsonb) END)
             ORDER BY ord.o, ord.bucket) FILTER (WHERE ord.is_debt), '[]'::jsonb),
           max(g.total), max(g.assets), max(g.debts), COALESCE(bool_or(g.gap), false)
      INTO v_classes, v_debt_it, v_total, v_assets, v_debts, v_gap
      FROM g LEFT JOIN ord ON true;

    -- Kinder (nur Haushalts-Betrachter): je Kind Netto + aufklappbar je Anlageart
    IF v_hh THEN
        WITH k AS (
            SELECT hp.person_id, hp.full_name, n.bucket, sum(n.value_eur) AS val, bool_or(n.has_fx_gap) AS gap
              FROM finance.networth_by_asset_class n
              JOIN core.fn_household_persons() hp ON hp.person_id = n.owner_person_id AND hp.role = 'child'
             GROUP BY hp.person_id, hp.full_name, n.bucket
        ), kp AS (
            -- je Person (nicht je Name: zwei Kinder mit gleichem Namen bleiben zwei Zeilen)
            SELECT k.person_id, k.full_name, sum(k.val) AS val, bool_or(k.gap) AS gap,
                   jsonb_agg(jsonb_build_object(
                       'label', jsonb_build_object('kind', 'enum', 'enum', 'finance.enum.asset_bucket', 'value', k.bucket),
                       'value', core.fn_ui_money(k.val, 'EUR'))
                     ORDER BY array_position(ARRAY['cash', 'fixed_deposit', 'p2p', 'depot', 'real_estate', 'pension', 'loan'],
                                             k.bucket), k.bucket) AS details
              FROM k
             GROUP BY k.person_id, k.full_name
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'label', kp.full_name,
                   'sub', NULL,
                   'value', core.fn_ui_money(COALESCE(kp.val, 0), 'EUR'),
                   'gap', kp.gap,
                   'pill', NULL,
                   'progress', NULL,
                   'target', NULL,
                   'details', kp.details)
                 ORDER BY kp.full_name, kp.person_id), '[]'::jsonb)
          INTO v_kids
          FROM kp;
    ELSE
        v_kids := '[]'::jsonb;
    END IF;

    -- Konten (ohne Kinder): Saldo in Kontowaehrung, gap = Saldo ohne Wechselkurs, Besitzer nur fuer den Haushalt.
    -- (Was davon fuer Sparziele verplant ist, zeigt EIN Ort: Bildschirm Ziele, Abschnitt „Fuer Ziele verplant".)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', a.name,
               'sub', CASE
                   WHEN v_hh AND a.last_reconciled_at IS NOT NULL
                   THEN core.fn_ui_tpl('finance.app.overview.owner_confirmed', jsonb_build_object(
                            'owner', COALESCE(to_jsonb(hp.full_name), core.fn_ui_tpl('finance.app.common.joint')),
                            'date', core.fn_ui_date(a.last_reconciled_at)))
                   WHEN v_hh
                   THEN core.fn_ui_tpl('finance.app.overview.owner', jsonb_build_object(
                            'owner', COALESCE(to_jsonb(hp.full_name), core.fn_ui_tpl('finance.app.common.joint'))))
                   WHEN a.last_reconciled_at IS NOT NULL
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
      LEFT JOIN core.fn_household_persons() hp ON hp.person_id = a.owner_person_id
     WHERE a.status = 'active'
       AND a.account_type IN ('cash', 'fixed_deposit', 'p2p')
       AND ((v_hh AND hp.role IS DISTINCT FROM 'child') OR (NOT v_hh AND a.owner_person_id = v_pid));

    -- Besitz immer (mit Leer-Text), Schulden/Kinder nur mit Eintraegen, Konten immer
    v_sections := jsonb_build_array(jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.overview.section_assets'),
        'value', CASE WHEN jsonb_array_length(v_classes) > 0 THEN core.fn_ui_money(v_assets, 'EUR') END,
        'empty', v_empty, 'items', v_classes));
    IF jsonb_array_length(v_debt_it) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.overview.section_debts'),
            'value', core.fn_ui_money(v_debts, 'EUR'),
            'empty', v_empty, 'items', v_debt_it);
    END IF;
    IF jsonb_array_length(v_kids) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.overview.section_kids'),
            'value', NULL,
            'empty', v_empty, 'items', v_kids);
    END IF;
    v_sections := v_sections || jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.overview.section_accounts'),
        'value', NULL,
        'empty', v_empty, 'items', v_accts);

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.overview.title'),
        'hero', jsonb_build_object(
            'label', CASE WHEN v_hh THEN core.fn_ui_tpl('finance.app.overview.hero')
                          ELSE core.fn_ui_tpl('finance.app.overview.hero_own') END,
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap,
            'note', CASE WHEN v_debts < 0 THEN core.fn_ui_tpl('finance.app.overview.hero_note', jsonb_build_object(
                             'assets', core.fn_ui_money(v_assets, 'EUR'),
                             'debts', core.fn_ui_money(-v_debts, 'EUR'))) END),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_overview(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
