-- tests/db/finance/test_fn_app_screen_accounts.sql
-- finance.fn_app_screen_accounts(p) — Mini-App-Bildschirm „Konten“ (UX-Gesamtkonzept 2026-10-31, 5.2) auf dem
--   Fixture-Haushalt tests/util/util_app_household.sql:
--   [1] Owner: je Geld-Konto ein Abschnitt, keine Kinder-Konten, kein 0-EUR-Konto ohne Bewegung (B10), kein Hero (B8),
--       kein Abschnittswert (B6); Reihenfolge nach Kontoart, gemeinsame vor eigenen (Owner-Abnahme 2026-10-31); jede
--       Karte vier Zeilen, „Zurueckgelegt fuer Ziele“ immer; fn_app_view_lint = 0
--   [2] Zeilen: Sparkonto „Stand heute · davon frei“ + „Reicht bis {Monat}“ mit warn „x im Monat mehr ab als rein“
--       (B1/B2); Girokonto mit Bruecke <= 8 Zeilen und Kontoauszug-Datum im Aufklappen; Gemeinschaftskonto ohne Auszug
--       -> „Kontoauszug: noch keiner“ + „Tiefster Stand —“ mit Grund im Aufklappen, Einzelposten gedeckelt; Tagesgeld
--       ohne Bewegung -> „0 · keine Zahlungen“; Gehen ab / Kommen rein im naechsten Monat getrennt, nie netto, an
--       jedem Stichtag des Monats (eigene Abbuchung am 28.)
--   [3] Partnerin sieht dasselbe wie der Owner
--   [4] Kind: nur eigenes Konto, kein Haushaltsname (Volltextsuche), Eingang vom Haushalt neutral; Lint = 0
--   [5] Gast ohne Daten: ein leerer Abschnitt; probe empty
--   [6] probe: Banner nur alert/warn, Ziel accounts, Ziel-Geld-Luecke nur alert; Frei-SQL / kaputte Eingabe
--   [7] fn_app_accounts_listed: die eine Regel (Haushalt ohne Kinder-Konten, sonst eigene)
BEGIN;
\ir ../../util/util_app_household.sql

DO $$
DECLARE
  v jsonb; v2 jsonb; s jsonb; it jsonb; v_txt text; v_names text[]; v_lint text; v_rest boolean; v_from date;
  k_spar text := 'Sparkonto Zins'; v_p2p_id int;
BEGIN
  -- [1] Owner
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_typeof(v->'hero') <> 'null'
     OR v->'title' <> core.fn_ui_tpl('finance.app.accounts.title') THEN
    RAISE EXCEPTION 'FAIL [1a] ok, Titel, kein Hero, got %', v; END IF;
  SELECT array_agg(x->'title'->'params'->>'account' ORDER BY o) INTO v_names
    FROM jsonb_array_elements(v->'sections') WITH ORDINALITY q(x, o);
  IF NOT v_names @> ARRAY['Girokonto Jonas', 'Gemeinschaftskonto', 'Sparkonto Zins', 'Broker-Cash Jonas', 'Tagesgeld Mira']
     OR v_names && ARRAY['Taschengeld Lea', 'Taschengeld Tom', 'Verrechnungskonto Krypto'] THEN
    RAISE EXCEPTION 'FAIL [1b] Konten-Menge (ohne Kinder, ohne 0-EUR-Konto), got %', v_names; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') x WHERE jsonb_typeof(COALESCE(x->'value', 'null'::jsonb)) <> 'null') THEN
    RAISE EXCEPTION 'FAIL [1c] kein Abschnittswert'; END IF;
  -- Reihenfolge nach Kontoart (Owner-Abnahme 2026-10-31): Girokonten (gemeinsames zuerst) -> Tagesgeld/Spar-/Verrechnungskonten
  -- (nach Namen); das Sparkonto mit Warnung bleibt an seinem Platz. P2P steht zuletzt -> [7b]
  IF v_names IS DISTINCT FROM ARRAY['Gemeinschaftskonto', 'Girokonto Jonas', 'Broker-Cash Jonas', 'Sparkonto Zins', 'Tagesgeld Mira'] THEN
    RAISE EXCEPTION 'FAIL [1d] Reihenfolge nach Kontoart, got %', v_names; END IF;
  -- jede Karte gleich gebaut: vier Zeilen, „Zurueckgelegt fuer Ziele“ immer im Aufklappen von „Stand heute“
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') x
              WHERE jsonb_array_length(x->'items') <> 4
                 OR NOT (x->'items'->0->'details' @> jsonb_build_array(jsonb_build_object(
                           'label', core.fn_ui_tpl('finance.app.accounts.d_reserved'))))) THEN
    RAISE EXCEPTION 'FAIL [1d2] vier Zeilen je Karte, Zurueckgelegt fuer Ziele immer, got %', v; END IF;
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1e] fn_app_view_lint Owner: %', v_lint; END IF;
  RAISE NOTICE 'PASS [1] Owner: Konten-Menge, Reihenfolge, kein Hero/Abschnittswert, Lint = 0';

  -- [2] Zeilen
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = k_spar;
  IF s->'items'->0->'label' <> core.fn_ui_tpl('finance.app.accounts.balance_today')
     OR s->'items'->0->'value' <> core.fn_ui_money(28000, 'EUR')
     OR s->'items'->0->'sub' <> core.fn_ui_tpl('finance.app.accounts.free_of', jsonb_build_object('amount', core.fn_ui_money(11150, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [2a] Sparkonto Stand heute · davon 11150 frei, got %', s->'items'->0; END IF;
  -- Sparkonto (Quelle funding): „Reicht bis {Monat}“ statt eines (negativen) tiefsten Stands; die Pille sagt, warum:
  -- 2400 ab, 185 rein -> 2215 im Monat mehr ab als rein (Owner-Abnahme 2026-10-31)
  it := s->'items'->1;
  IF it->'label' <> core.fn_ui_tpl('finance.app.accounts.until') OR it->'value'->>'kind' <> 'month'
     OR it->'value' <> core.fn_ui_month((finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_sparkonto'))->>'on_date')::date)
     OR it->'pill'->>'state' <> 'warn'
     OR it->'pill'->'text' <> core.fn_ui_tpl('finance.app.accounts.pill_net_out')
     OR it->'details'->0->'label' <> core.fn_ui_tpl('finance.app.accounts.i_net_out', jsonb_build_object('amount', core.fn_ui_money(2215, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [2b] Sparkonto Reicht bis {Monat}, warn 2215 im Monat mehr ab als rein, got %', it; END IF;
  -- Girokonto: Bruecke <= 8 Zeilen, Gehen ab / Kommen rein
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = 'Girokonto Jonas';
  SELECT i INTO it FROM jsonb_array_elements(s->'items') i WHERE i->'label' = core.fn_ui_tpl('finance.app.accounts.low');
  IF it IS NULL OR jsonb_array_length(it->'details') > 8 OR jsonb_array_length(it->'details') < 3 THEN
    RAISE EXCEPTION 'FAIL [2c] Girokonto: Tiefster Stand mit Bruecke (3..8 Zeilen), got %', it; END IF;
  -- die Pille kommt allein aus fn_app_low_state_pill (dieselbe wie am Sparplan; „x unter dem Puffer" = short_by)
  IF it->'pill' IS DISTINCT FROM finance.fn_app_low_state_pill(finance.fn_account_low_state(
       (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas'))) THEN
    RAISE EXCEPTION 'FAIL [2c2] Girokonto: Pille = fn_app_low_state_pill(fn_account_low_state), got %', it->'pill'; END IF;
  -- Gehen ab / Kommen rein: bis zum 15. „noch im <laufenden Monat>“, danach „im <naechsten Monat>“, getrennt, nie netto.
  -- Die Fixture-Abgaenge liegen am 1. und 12.: vom 13. bis 15. ist der Rest des Monats leer (0 · keine Zahlungen). Darum
  -- eine eigene Abbuchung am 28. und das Gehalt am Monatsletzten: beide liegen an jedem Tag im Fenster (Tag <= 15 ->
  -- [heute, Monatsende] mit heute <= 28; sonst der ganze naechste Monat). [2d] prueft am Datum des Laufs, [2d3] die
  -- uebrigen Stichtage.
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Fenster-Abo Test', (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas'), -12, 'month', 28,
          (date_trunc('month', current_date) + interval '27 days')::date, current_date - 30);
  SELECT x INTO s FROM jsonb_array_elements(finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb))->'sections') x
   WHERE x->'title'->'params'->>'account' = 'Girokonto Jonas';
  v_rest := extract(day FROM current_date) <= 15;
  v_from := CASE WHEN v_rest THEN current_date ELSE (date_trunc('month', current_date) + interval '1 month')::date END;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i
                  WHERE i->'label' = core.fn_ui_tpl(CASE WHEN v_rest THEN 'finance.app.accounts.out_month_rest' ELSE 'finance.app.accounts.out_month' END,
                                         jsonb_build_object('month', core.fn_ui_month(v_from, true)))
                    AND (i->'value'->>'value')::numeric < 0)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i
                     WHERE i->'label' = core.fn_ui_tpl(CASE WHEN v_rest THEN 'finance.app.accounts.in_month_rest' ELSE 'finance.app.accounts.in_month' END,
                                            jsonb_build_object('month', core.fn_ui_month(v_from, true)))
                       AND (i->'value'->>'value')::numeric > 0) THEN
    RAISE EXCEPTION 'FAIL [2d] Girokonto: Gehen ab (< 0) und Kommen rein (> 0) im naechsten Monat getrennt, got %', s; END IF;
  -- [2d3] dieselbe Fenster-Regel fuer andere Stichtage (1., 13., 15., 16., 28., Monatsletzter des naechsten Monats): die
  -- Vorkommen haengen nur am Fenster (fn_app_payment_occurrences hat kein eigenes Datum) -> Abgang und Eingang immer da
  DECLARE d date; w_from date; w_until date; o jsonb; BEGIN
    FOREACH d IN ARRAY (SELECT array_agg((date_trunc('month', current_date) + interval '1 month')::date + k)
                          FROM unnest(ARRAY[0, 12, 14, 15, 27]) k)
                       || ((date_trunc('month', current_date) + interval '2 months - 1 day')::date) LOOP
      w_from := CASE WHEN extract(day FROM d) <= 15 THEN d ELSE (date_trunc('month', d) + interval '1 month')::date END;
      w_until := CASE WHEN extract(day FROM d) <= 15 THEN (date_trunc('month', d) + interval '1 month - 1 day')::date
                      ELSE (date_trunc('month', d) + interval '2 months - 1 day')::date END;
      o := finance.fn_app_payment_occurrences((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas'), w_from, w_until, true, 'fxh_jonas');
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o->'rows') r WHERE (r->>'amount')::numeric < 0)
         OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o->'rows') r WHERE (r->>'amount')::numeric > 0) THEN
        RAISE EXCEPTION 'FAIL [2d3] Stichtag %: Fenster % .. % ohne Abgang oder Eingang, got %', d, w_from, w_until, o; END IF;
    END LOOP;
  END;
  DELETE FROM finance.recurring_payments WHERE name = 'Fenster-Abo Test';
  -- Kontoauszug bei jedem Konto im Aufklappen von „Stand heute“: Girokonto mit Datum
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items'->0->'details') d
                  WHERE d->'label' = core.fn_ui_tpl('finance.app.accounts.d_statement') AND d->'value'->>'kind' = 'date') THEN
    RAISE EXCEPTION 'FAIL [2d2] Girokonto: Kontoauszug-Datum im Aufklappen, got %', s->'items'->0; END IF;
  -- Gemeinschaftskonto: kein Auszug -> „Kontoauszug: noch keiner“; „Tiefster Stand —“, aufgeklappt was fehlt; keine
  -- Abschnitts-Notiz; Einzelposten gedeckelt
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = 'Gemeinschaftskonto';
  IF s ? 'note'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items'->0->'details') d
                     WHERE d->'label' = core.fn_ui_tpl('finance.app.accounts.d_statement')
                       AND d->'value' = core.fn_ui_tpl('finance.app.accounts.d_statement_none'))
     OR s->'items'->1->'label' <> core.fn_ui_tpl('finance.app.accounts.low')
     OR jsonb_typeof(s->'items'->1->'value') <> 'null' OR jsonb_typeof(s->'items'->1->'pill') <> 'null'
     OR s->'items'->1->'details' <> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.accounts.d_no_preview'), 'value', NULL))
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i WHERE jsonb_array_length(COALESCE(i->'details', '[]'::jsonb)) > 8) THEN
    RAISE EXCEPTION 'FAIL [2e] Gemeinschaftskonto: Kontoauszug „noch keiner“, Tiefster Stand — mit Grund, keine Notiz, Deckel, got %', s; END IF;
  -- Tagesgeld Mira (Auszug, keine Bewegung): trotzdem vier Zeilen, „Gehen ab“ / „Kommen rein“ mit 0 · keine Zahlungen
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = 'Tagesgeld Mira';
  IF jsonb_array_length(s->'items') <> 4
     OR s->'items'->2->'value' <> core.fn_ui_money(0, 'EUR') OR s->'items'->2->'sub' <> core.fn_ui_tpl('finance.app.accounts.n_payments_none')
     OR s->'items'->3->'value' <> core.fn_ui_money(0, 'EUR') OR s->'items'->3->'sub' <> core.fn_ui_tpl('finance.app.accounts.n_incoming_none')
     OR jsonb_array_length(s->'items'->2->'details') <> 0 THEN
    RAISE EXCEPTION 'FAIL [2f] Tagesgeld ohne Bewegung: vier Zeilen, 0 · keine Zahlungen / Eingaenge, got %', s; END IF;
  RAISE NOTICE 'PASS [2] Zeilen: frei, Reicht bis, Bruecke, Kontoauszug, Deckel, getrennte Ab-/Eingaenge';

  -- [3] Partnerin = Owner
  v2 := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_mira', 'params', '{}'::jsonb));
  IF v2 <> v THEN RAISE EXCEPTION 'FAIL [3] Partnerin sieht anderes als der Owner'; END IF;
  RAISE NOTICE 'PASS [3] Partnerin = Owner';

  -- [4] Kind: nur eigenes Konto, kein Haushaltsname
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_lea', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF jsonb_array_length(v->'sections') <> 1 OR v->'sections'->0->'title'->'params'->>'account' <> 'Taschengeld Lea'
     OR v_txt LIKE '%Girokonto%' OR v_txt LIKE '%Gemeinschaftskonto%' OR v_txt LIKE '%Jonas%' OR v_txt LIKE '%Mira%' THEN
    RAISE EXCEPTION 'FAIL [4a] Kind: nur eigenes Konto, keine Eltern-/Haushaltsnamen, got %', v; END IF;
  -- Eingang vom Haushalt neutral: ueber ein Fenster, das den Taschengeld-Termin sicher enthaelt (das Fenster der Seite
  -- haengt vom Tag im Monat ab), mit derselben Zeilen-fn wie der Bildschirm
  IF finance.fn_app_payment_occurrences((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_cash_lea'),
                                        current_date, current_date + 40, false, 'fxh_lea')::text
     NOT LIKE '%finance.app.accounts.from_household%' THEN
    RAISE EXCEPTION 'FAIL [4b] Eingang vom Haushalt neutral, got %', v; END IF;
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4c] Lint Kind: %', v_lint; END IF;
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_tom', 'params', '{}'::jsonb));
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF jsonb_array_length(v->'sections') <> 1 OR v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4d] Tom: %, %', v, v_lint; END IF;
  RAISE NOTICE 'PASS [4] Kinder: nur Eigenes, Haushalt neutral, Lint = 0';

  -- [5] Gast ohne Daten
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_gast', 'params', '{}'::jsonb));
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 0 OR v_lint IS NOT NULL
     OR (finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_gast', 'params', '{"probe":true}'::jsonb))->>'empty')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [5] Gast: leerer Abschnitt + probe empty, got % / %', v, v_lint; END IF;
  RAISE NOTICE 'PASS [5] Gast ohne Daten';

  -- [6] probe + Fehler
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{"probe":true}'::jsonb));
  IF (v->>'empty')::boolean OR jsonb_typeof(v->'banners') <> 'array' OR v ? 'sections'
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'banners') b
                 WHERE b->>'state' NOT IN ('alert', 'warn') OR b->'target'->>'screen' <> 'accounts'
                    OR (b->'text'->>'value' = 'finance.app.accounts.banner_gap' AND b->>'state' <> 'alert')) THEN
    RAISE EXCEPTION 'FAIL [6a] probe: Banner nur alert/warn, Ziel accounts, Luecke nur alert, got %', v; END IF;
  IF finance.fn_app_screen_accounts('"x"'::jsonb)->>'code' <> 'bad_request'
     OR finance.fn_app_screen_accounts('{"params":{}}'::jsonb)->>'code' <> 'bad_request' THEN
    RAISE EXCEPTION 'FAIL [6b] kaputte Eingabe -> bad_request'; END IF;
  RAISE NOTICE 'PASS [6] probe + bad_request';

  -- [7] die eine Regel der Konten-Menge
  IF EXISTS (SELECT 1 FROM finance.fn_app_accounts_listed('fxh_jonas') l(id) JOIN finance.accounts a ON a.id = l.id
              WHERE a.owner_person_id IN ('fxh_lea', 'fxh_tom'))
     OR EXISTS (SELECT 1 FROM finance.fn_app_accounts_listed('fxh_lea') l(id) JOIN finance.accounts a ON a.id = l.id
                 WHERE a.owner_person_id IS DISTINCT FROM 'fxh_lea')
     OR NOT EXISTS (SELECT 1 FROM finance.fn_app_accounts_listed('fxh_lea')) THEN
    RAISE EXCEPTION 'FAIL [7] fn_app_accounts_listed'; END IF;
  RAISE NOTICE 'PASS [7] fn_app_accounts_listed';

  -- [7b] Kontoart P2P steht hinter allen Geld-Konten (der Fixture-Haushalt hat keins, daher nur hier)
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Beispiel P2P', 'p2p', 'EUR', 'active', 'fxh_jonas') RETURNING id INTO v_p2p_id;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_p2p_id, 500, current_date - 40, 'other');
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  SELECT array_agg(x->'title'->'params'->>'account' ORDER BY o) INTO v_names
    FROM jsonb_array_elements(v->'sections') WITH ORDINALITY q(x, o);
  IF v_names[array_length(v_names, 1)] IS DISTINCT FROM 'Beispiel P2P' THEN
    RAISE EXCEPTION 'FAIL [7b] P2P zuletzt, got %', v_names; END IF;
  RAISE NOTICE 'PASS [7b] P2P hinter den Geld-Konten';
END $$;

-- [8] Frei-SQL-Rollen: kein EXECUTE; selbst MIT Test-Grant -> forbidden (Muster test_fn_app_screen_overview)
DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_accounts(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [8a] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler'; END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_accounts(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
DECLARE v jsonb;
BEGIN
  v := finance.fn_app_screen_accounts('{"person_id":"fxh_jonas","params":{}}');
  IF v <> '{"ok":false,"code":"forbidden"}'::jsonb THEN RAISE EXCEPTION 'FAIL [8b] Frei-SQL -> forbidden, got %', v; END IF;
  RAISE NOTICE 'PASS [8] Frei-SQL-Sitzung -> forbidden';
END $$;

ROLLBACK;
