-- ============================================================
-- util_seed_test_fixtures.sql — Fixture-Seed fuer die Routing-Suite (Tier 2)
-- HINTERGRUND: tests/agent/finance/finance_cases.json referenziert benannte Entitaeten
--   (Lindenbank Giro, Testbroker Depot, VWCE, Baufinanzierung Buchenbank, ...). Nach
--   util_reset_user_data.sql (Neu-User-Reset) fehlen sie -> 23/40 Cases failen
--   "leer", obwohl der Agent sich korrekt verhaelt (fragt nach statt Tool-Call).
--   Dieses Seed stellt GENAU die von den Cases vorausgesetzten Entitaeten her.
-- IDEMPOTENT: jede Entitaet wird per Name-Lookup geprueft und nur bei Fehlen
--   ueber die offiziellen agent.fn_create_*/fn_book_*-Functions angelegt
--   (Trigger pflegen balance/shares/avg — nie direkt schreiben).
-- PFLEGE-REGEL: Single-Source der Namensliste ist tests/fixtures/fixtures.json (der Pre-Flight
--   in scripts/n8n_test.ps1 + scripts/test_fixtures.ps1 -Verify lesen NUR diese). Neue
--   Case-Entitaet => Manifest-Eintrag dort UND hier den fn_create_*-Block ergaenzen; doc_lint
--   erzwingt Manifest-subset-Seed (jede gepruefte Entitaet wird hier auch angelegt).
-- DARF NICHT ANGELEGT WERDEN (Cases erwarten "frei" fuer create_*-Dedup):
--   Sparziel 'Notfallfonds' (tc18), Recurring 'Netflix' (tc24), Sparplan
--   'EIMI Monatsplan' (tc33 LEGT IHN AN; anderes Wertpapier als der Bestandsplan, sonst fragt der Agent
--   wegen des gleichen Symbols zu Recht nach), Konten Eichenbank/Probebroker/N26/Ahornbank
--   (tc01/02/09/10/12), KEIN Crypto-Depot (tc15), KEINE Pension (tc25).
-- BESTEHENDER Sparplan 'VWCE Bestandsplan' (tc34/35/36 book/set/close auf einem
--   EXISTIERENDEN Plan; eigener Name + anderes Wertpapier als tc33 'EIMI Monatsplan').
-- ONBOARDING: am Ende werden alle Sektionen auf 'completed' gesetzt — der Fixture-User
--   ist ein etablierter Nutzer (loest den Advisor-Onboarding-Gate + die Finance-Nudges).
-- Usage:   db_apply.ps1 -File tests\fixtures\util_seed_test_fixtures.sql
-- ============================================================
BEGIN;

-- {ok:false}-Rueckgaben der fns zu harten Fehlern machen (Seed muss vollstaendig sein).
-- pg_temp: session-lokal, verschwindet nach dem Lauf — kein Katalog-/Schema-Eintrag.
CREATE FUNCTION pg_temp.assert_ok(p_label text, p_res jsonb) RETURNS void AS $$
BEGIN
    IF COALESCE((p_res->>'ok')::boolean, TRUE) = FALSE THEN
        RAISE EXCEPTION 'fixture seed: % fehlgeschlagen: %', p_label, p_res->>'reason';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE
    v_lindenbank   INT;    -- Lindenbank Giro
    v_trc   INT;    -- Testbroker Cash Girokonto
    v_cash  INT;    -- Bargeld
    v_depot INT;    -- Testbroker Depot
    v_r     JSONB;  -- fn-Ergebnis ({ok:false} ohne RAISE -> hier hart machen)
    v_rate_day DATE; -- naechste Rate der Baufinanzierung Buchenbank
    v_created TEXT[] := '{}';
BEGIN
    -- ---------- Konten (cash) ----------
    SELECT id INTO v_lindenbank FROM finance.accounts WHERE lower(name) = lower('Lindenbank Giro');
    IF v_lindenbank IS NULL THEN
        v_r := finance.fn_create_account(jsonb_build_object(
            'name','Lindenbank Giro', 'account_type','cash', 'bank','Lindenbank',
            'account_holder','Erika', 'currency','EUR',
            'account_number','DE21 1234 5678 0000 0123 45'));   -- Monats-Check: der Mock-Kontoauszug (tc51) findet das Konto per IBAN
        PERFORM pg_temp.assert_ok('Lindenbank Giro', v_r);
        SELECT id INTO v_lindenbank FROM finance.accounts WHERE lower(name) = lower('Lindenbank Giro');
        v_r := finance.fn_book_transaction(jsonb_build_object(
            'account_id', v_lindenbank, 'amount', 2500, 'direction','inflow',
            'description','Eroeffnungssaldo (Testfixture)',
            'transaction_date', (CURRENT_DATE - 90)::text));
        PERFORM pg_temp.assert_ok('Lindenbank Giro Eroeffnungssaldo', v_r);
        v_created := array_append(v_created, 'Lindenbank Giro');
    END IF;

    SELECT id INTO v_trc FROM finance.accounts WHERE lower(name) = lower('Testbroker Cash Girokonto');
    IF v_trc IS NULL THEN
        v_r := finance.fn_create_account(jsonb_build_object(
            'name','Testbroker Cash Girokonto', 'account_type','cash',
            'bank','Trade Republic', 'account_holder','Erika', 'currency','EUR'));
        PERFORM pg_temp.assert_ok('Testbroker Cash Girokonto', v_r);
        SELECT id INTO v_trc FROM finance.accounts WHERE lower(name) = lower('Testbroker Cash Girokonto');
        v_r := finance.fn_book_transaction(jsonb_build_object(
            'account_id', v_trc, 'amount', 5000, 'direction','inflow',
            'description','Eroeffnungssaldo (Testfixture)',
            'transaction_date', (CURRENT_DATE - 90)::text));
        PERFORM pg_temp.assert_ok('Testbroker Cash Eroeffnungssaldo', v_r);
        v_created := array_append(v_created, 'Testbroker Cash Girokonto');
    END IF;

    SELECT id INTO v_cash FROM finance.accounts WHERE lower(name) = lower('Bargeld');
    IF v_cash IS NULL THEN
        v_r := finance.fn_create_account(jsonb_build_object(
            'name','Bargeld', 'account_type','cash',
            'account_holder','Erika', 'currency','EUR'));
        PERFORM pg_temp.assert_ok('Bargeld', v_r);
        SELECT id INTO v_cash FROM finance.accounts WHERE lower(name) = lower('Bargeld');
        v_r := finance.fn_book_transaction(jsonb_build_object(
            'account_id', v_cash, 'amount', 100, 'direction','inflow',
            'description','Eroeffnungssaldo (Testfixture)',
            'transaction_date', (CURRENT_DATE - 90)::text));
        PERFORM pg_temp.assert_ok('Bargeld Eroeffnungssaldo', v_r);
        v_created := array_append(v_created, 'Bargeld');
    END IF;

    -- ---------- Depot (Verrechnungskonto = Testbroker Cash; tc23 setzt diese Abhaengigkeit voraus) ----------
    SELECT id INTO v_depot FROM finance.accounts WHERE lower(name) = lower('Testbroker Depot');
    IF v_depot IS NULL THEN
        v_r := finance.fn_create_account(jsonb_build_object(
            'name','Testbroker Depot', 'account_type','stocks_depot',
            'bank','Trade Republic', 'account_holder','Erika', 'currency','EUR',
            'settlement_id', v_trc));
        PERFORM pg_temp.assert_ok('Testbroker Depot', v_r);
        SELECT id INTO v_depot FROM finance.accounts WHERE lower(name) = lower('Testbroker Depot');
        v_created := array_append(v_created, 'Testbroker Depot');
    END IF;

    -- ---------- VWCE-Holding (30 Stueck: > 5 fuer tc16-Sell, << 5000 fuer tc54-Oversell) ----------
    IF NOT EXISTS (SELECT 1 FROM finance.depot_holdings
                   WHERE account_id = v_depot AND isin = 'IE00BK5BQT80') THEN
        v_r := finance.fn_book_stock_buy(jsonb_build_object(
            'depot_id', v_depot, 'settlement_id', v_trc,
            'isin','IE00BK5BQT80', 'symbol','VWCE', 'name','Vanguard FTSE All-World',
            'shares', 30, 'price_per_share', 100, 'order_fee', 1,
            'transaction_date', (CURRENT_DATE - 60)::text));
        PERFORM pg_temp.assert_ok('VWCE-Kauf', v_r);
        v_created := array_append(v_created, 'VWCE-Holding (30 Stk)');
    END IF;

    -- ---------- Kredit (Restschuld 250k: >> 1200-Rate fuer tc17, << 999999 fuer tc22) ----------
    -- Naechste Rate in spaetestens 7 Tagen (tc74 "die faellige Rate"): die Raten-Kette gilt erst ab heute, ein fester Tag
    -- liesse je nach Kalendertag keine offene Rate im Fenster von fn_get_loan_payment_split (+14 Tage). Tag bis 28 (CHECK).
    IF NOT EXISTS (SELECT 1 FROM finance.loans WHERE lower(name) = lower('Baufinanzierung Buchenbank')) THEN
        v_rate_day := CURRENT_DATE + 7;
        IF extract(day FROM v_rate_day) > 28 THEN v_rate_day := date_trunc('month', v_rate_day)::date + 27; END IF;
        v_r := finance.fn_create_loan(jsonb_build_object(
            'name','Baufinanzierung Buchenbank', 'lender','Buchenbank', 'borrower','Erika',
            'original_amount', 300000, 'current_balance', 250000,
            'disbursement_date','2024-03-01', 'interest_rate', 3.8,
            'monthly_annuity', 1200, 'schedule_day_of_month', extract(day FROM v_rate_day)::int,
            'first_payment_date', v_rate_day::text,
            'debit_account_id', v_lindenbank));
        PERFORM pg_temp.assert_ok('Baufinanzierung Buchenbank', v_r);
        v_created := array_append(v_created, 'Baufinanzierung Buchenbank');
    END IF;

    -- ---------- Versicherung (tc29 set_insurance / tc37 close_insurance) ----------
    IF NOT EXISTS (SELECT 1 FROM finance.insurances WHERE lower(name) = lower('Lindenversicherung Hausratversicherung')) THEN
        v_r := finance.fn_create_insurance(jsonb_build_object(
            'name','Lindenversicherung Hausratversicherung', 'insurance_company','Lindenversicherung',
            'policy_number','HR-FIXTURE-001', 'policyholder','Erika',
            'premium_amount', 89,
            'schedule_interval', 1, 'schedule_unit','year', 'schedule_day_of_month', 15,
            'valid_from','2026-01-01', 'first_payment_date','2026-01-15',
            'debit_account_id', v_lindenbank));
        PERFORM pg_temp.assert_ok('Lindenversicherung Hausratversicherung', v_r);
        v_created := array_append(v_created, 'Lindenversicherung Hausratversicherung');
    END IF;

    -- ---------- Immobilie (tc28 Neubewertung / tc38 Hard-DELETE: KEIN Kredit verknuepfen!) ----------
    IF NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE lower(name) = lower('Musterimmobilie')) THEN
        v_r := finance.fn_create_real_estate(jsonb_build_object(
            'name','Musterimmobilie', 'current_value', 320000,
            'value_updated_at', CURRENT_DATE::text, 'owner','Erika'));
        PERFORM pg_temp.assert_ok('Musterimmobilie', v_r);
        v_created := array_append(v_created, 'Musterimmobilie');
    END IF;

    -- ---------- Bestehender Sparplan (tc34 book / tc35 set / tc36 close auf EXISTIERENDEM Plan) ----------
    -- Eigener Name 'VWCE Bestandsplan' — tc33 legt 'EIMI Monatsplan' (anderes Wertpapier) an, der muss frei bleiben.
    -- Testbroker Depot (stocks_depot, settlement = Testbroker Cash) ist oben geseedet -> fn loest depot_name auf.
    IF NOT EXISTS (SELECT 1 FROM finance.savings_plans WHERE lower(name) = lower('VWCE Bestandsplan')) THEN
        v_r := finance.fn_create_savings_plan(jsonb_build_object(
            'name','VWCE Bestandsplan', 'depot_name','Testbroker Depot',
            'isin','IE00BK5BQT80', 'symbol','VWCE', 'security_name','Vanguard FTSE All-World',
            'amount', 50, 'schedule_interval', 1, 'schedule_unit','month',
            'schedule_day_of_month', 2, 'first_payment_date','2026-07-02'));  -- Ausfuehrungstag der Bank (fn_broker_plan_days)
        PERFORM pg_temp.assert_ok('VWCE Bestandsplan', v_r);
        v_created := array_append(v_created, 'VWCE Bestandsplan');
    END IF;

    -- ---------- Standalone Dauerauftrag (tc42 book_recurring_occurrence: Betrags-Anpassung am Stichtag) ----------
    -- Monatliche Ausgabe (80) auf Lindenbank Giro; erste Zahlung 30 Tage zurueck -> ein OFFENES Vorkommen
    -- im 90-Tage-Fenster (der Agent kann den Ist-Betrag anpassen). Eigener Name (kein tc24-Netflix-Dub).
    IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE lower(name) = lower('Stromabschlag Stadtwerke')) THEN
        v_r := finance.fn_create_recurring_payment(jsonb_build_object(
            'name','Stromabschlag Stadtwerke', 'account_id', v_lindenbank,
            'direction','expense', 'amount', 80,
            'schedule_interval', 1, 'schedule_unit','month',
            'first_payment_date', (CURRENT_DATE - 30)::text));
        PERFORM pg_temp.assert_ok('Stromabschlag Stadtwerke', v_r);
        v_created := array_append(v_created, 'Stromabschlag Stadtwerke');
    END IF;

    -- ---------- Noch nicht gestartete, jaehrliche Ausgabe (ac15: erfasst, Berater fragt nicht danach) ----------
    -- Erster Termin 200 Tage voraus -> innerhalb des eigenen Rhythmus, zaehlt also in der Monatsrechnung mit starts_on.
    -- Bewusst keine Einnahme: real_ingress ri07* braucht einen Haushalt ohne Einnahme (Plan-Knopf "es fehlen noch Daten").
    IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE lower(name) = lower('Jahresbeitrag Testfixture')) THEN
        v_r := finance.fn_create_recurring_payment(jsonb_build_object(
            'name','Jahresbeitrag Testfixture', 'account_id', v_lindenbank,
            'direction','expense', 'amount', 120,
            'schedule_interval', 1, 'schedule_unit','year',
            'first_payment_date', (CURRENT_DATE + 200)::text));
        PERFORM pg_temp.assert_ok('Jahresbeitrag Testfixture', v_r);
        v_created := array_append(v_created, 'Jahresbeitrag Testfixture');
    END IF;

    -- ---------- Verzinstes Konto (tc43 book_interest: DB-berechnete Zinsgutschrift am Stichtag) ----------
    -- cash-Konto mit 2% p.a. monatlich ab 60 Tage zurueck -> ein OFFENER Zins-Stichtag (valid_from + 1 Monat).
    -- Saldo 10000 -> fn_interest_amount_due rechnet ~16,67 (10000 * 2% / 12). Eigentuemer NULL = Haushalt.
    IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE lower(name) = lower('Tagesgeld Plus')) THEN
        v_r := finance.fn_create_account(jsonb_build_object(
            'name','Tagesgeld Plus', 'account_type','cash', 'bank','Lindenbank', 'currency','EUR',
            'interest_rate', 2, 'interest_credit_unit','month', 'interest_credit_day_of_month', -1,   -- zum Monatsende (Pflicht seit 2026-10-24)
            'interest_valid_from', (CURRENT_DATE - 60)::text));
        PERFORM pg_temp.assert_ok('Tagesgeld Plus', v_r);
        v_r := finance.fn_book_transaction(jsonb_build_object(
            'account_id', (SELECT id FROM finance.accounts WHERE lower(name) = lower('Tagesgeld Plus')),
            'amount', 10000, 'direction','inflow',
            'description','Eroeffnungssaldo (Testfixture)',
            'transaction_date', (CURRENT_DATE - 60)::text));
        PERFORM pg_temp.assert_ok('Tagesgeld Plus Eroeffnungssaldo', v_r);
        v_created := array_append(v_created, 'Tagesgeld Plus');
    END IF;

    -- ---------- Normale Buchung auf Lindenbank Giro (tc32 void_transaction: die "letzte Buchung" ist eine echte Ausgabe,
    -- nicht der Eroeffnungssaldo — sonst fragt der Agent zu Recht nach statt zu stornieren) ----------
    IF NOT EXISTS (SELECT 1 FROM finance.transactions
                   WHERE account_id = v_lindenbank AND description = 'Tankstelle (Testfixture)') THEN
        v_r := finance.fn_book_transaction(jsonb_build_object(
            'account_id', v_lindenbank, 'amount', 42.90, 'direction','outflow',
            'description','Tankstelle (Testfixture)',
            'transaction_date', (CURRENT_DATE - 5)::text));
        PERFORM pg_temp.assert_ok('Lindenbank Giro Tankstelle', v_r);
        v_created := array_append(v_created, 'Lindenbank Giro Tankstelle');
    END IF;

    -- ---------- Wechselkurs EUR/CLP (mc01/ac07 FX-Trigger: die Probe liest finance.fx_rates; ohne Kurs lehnt der
    -- Agent die Anlage korrekt ab). Je Lauf ein Kurs mit Datum HEUTE -> nie aelter als monitor.fx_stale_days. ----------
    PERFORM finance.fn_ensure_currency('CLP');
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
    VALUES ('EUR', 'CLP', 1450, CURRENT_DATE, 'testfixture')
    ON CONFLICT (base_currency, quote_currency, as_of) DO NOTHING;

    -- ---------- Kurs der VWCE-Holding (tc81: der heutige Depotwert zaehlt als Startbestand; ohne Kurs fragt der Agent zu
    -- Recht nach). Je Lauf ein Kurs mit Datum HEUTE, wie der Wechselkurs oben. ----------
    INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of, source)
    VALUES ('VWCE', 'IE00BK5BQT80', 110, 'EUR', CURRENT_DATE, 'testfixture')
    ON CONFLICT (symbol, as_of) DO NOTHING;

    IF array_length(v_created, 1) IS NULL THEN
        RAISE NOTICE 'FIXTURES OK: alle Entitaeten bereits vorhanden (nichts angelegt).';
    ELSE
        RAISE NOTICE 'FIXTURES ANGELEGT: %', array_to_string(v_created, ', ');
    END IF;
END $$;

-- ---------- Familienprofil: Lena Beispiel als Partnerin (tc07 Personenaufloesung, tc14 load_context) ----------
-- birth_date ist ein PLATZHALTER (Pflichtfeld des Facts-Validators, kein echtes Datum) —
-- das echte Onboarding ueberschreibt ihn. Append nur, wenn keine Person 'Lena' existiert;
-- der Validator-Trigger (trg_validate_household_facts) prueft den Write wie jeden anderen.
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
        (metadata->'facts'->'persons') || jsonb_build_object(
            'person_id',  'lena',
            'first_name', 'Lena',
            'last_name',  'Beispiel',
            'role',       'partner',
            'birth_date', '1982-09-10',
            'aliases',    jsonb_build_array('Ehefrau', 'Frau')))
WHERE name = 'family'
  AND NOT EXISTS (SELECT 1
                  FROM jsonb_array_elements(metadata->'facts'->'persons') p
                  WHERE lower(p->>'first_name') = 'lena');

-- ---------- Familienprofil: Lisa als Kind (gc06 Mitglied einladen: die Einladung geht nur an erfasste Personen) ----------
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
        (metadata->'facts'->'persons') || jsonb_build_object(
            'person_id',  'lisa',
            'first_name', 'Lisa',
            'last_name',  'Mustermann',
            'role',       'child',
            'birth_date', '2012-04-03',
            'aliases',    jsonb_build_array('Tochter')))
WHERE name = 'family'
  AND NOT EXISTS (SELECT 1
                  FROM jsonb_array_elements(metadata->'facts'->'persons') p
                  WHERE lower(p->>'first_name') = 'lisa');

DO $$
DECLARE v_n INT;
BEGIN
    SELECT count(*) INTO v_n FROM jsonb_array_elements(
        (SELECT metadata->'facts'->'persons' FROM agent.core_contexts WHERE name = 'family')) p
    WHERE lower(p->>'first_name') IN ('lena', 'lisa');
    IF v_n < 2 THEN
        RAISE EXCEPTION 'fixture seed: Lena oder Lisa fehlt nach UPDATE im family-Kontext';
    END IF;
    RAISE NOTICE 'FIXTURES OK: family enthaelt Lena (partner) + Lisa (child).';
END $$;

-- ---------- Veroeffentlichter Finanzplan mit REIT-Regeln (ac01 Plan-first: der Berater muss konkrete Plan-Regeln
-- zitieren — ohne publizierten Plan kann er das nicht) ----------
-- Ueber die offiziellen Schreibwege (Draft -> Publish), chat_id nicht-numerisch = Fixture-Pass-through wie die
-- E2E-Sentinels. Nur wenn noch kein aktiver Finanzplan existiert (idempotent; ein echter Advisor-Publish ersetzt ihn).
DO $$
DECLARE v_r JSONB;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = 'finance' AND person_id IS NULL AND status = 'active') THEN
        v_r := agent.fn_advisor_save_section(jsonb_build_object(
            'domain','finance', 'chat_id','test_fixture', 'plan_name','Haushaltsplan (Testfixture)',
            'section_key','reit_strategy',
            'section_content','REITs: optionale Beimischung von 6 % zur Streuung. Kauf-Trigger: nur unter 30 Euro je Anteil. Bevorzugt breite ETFs, keine Einzeltitel.'));
        PERFORM pg_temp.assert_ok('Finanzplan Sektion reit_strategy', v_r);
        v_r := agent.fn_advisor_publish_plan(jsonb_build_object(
            'domain','finance', 'chat_id','test_fixture',
            'plan_md', E'# Haushaltsplan (Testfixture)\n\n## REIT-Strategie\n- Optionale REIT-Beimischung: 6 % des Portfolios zur Streuung.\n- Kauf-Trigger: REITs nur unter 30 Euro je Anteil nachkaufen.\n- Form: breite ETFs, keine Einzeltitel.\n'));
        PERFORM pg_temp.assert_ok('Finanzplan Publish', v_r);
        RAISE NOTICE 'FIXTURES ANGELEGT: veroeffentlichter Finanzplan (REIT-Regeln).';
    END IF;
END $$;

-- ---------- Onboarding: alle Sektionen abgeschlossen (etablierter Fixture-User) ----------
-- Loest das Advisor-Onboarding-Pflicht-Gate (finance feature.onboarding_gate + P2b-1 career
-- feature.career_onboarding_gate) + die Finance-Self-Onboarding-Nudges. Die *.onboarding_state-
-- Tabellen seedet der Installer (household + 5 Finanz-Sektionen + 3 Career-Sektionen pro Person);
-- hier nur den Status auf 'completed' ziehen. to_regclass-Guard, falls eine Tabelle fehlt.
-- career ist PRO PERSON (P2b-1) — der Installer seedet die Owner-Zeilen; ein blanket-UPDATE
-- (nur der Owner existiert in den Fixtures) erfuellt das per-Person-Gate fuer den Test-Owner.
-- Phase B: generisch ueber die <pkg>.onboarding_state-Konvention (vorher finance/career fest, estate fehlte).
DO $$
DECLARE v_pkg text;
BEGIN
    IF to_regclass('agent.guide_onboarding_state') IS NOT NULL THEN
        UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE status <> 'completed';
    END IF;
    FOR v_pkg IN SELECT DISTINCT package FROM core.schema_version WHERE package <> 'core' LOOP
        IF to_regclass(format('%I.onboarding_state', v_pkg)) IS NOT NULL THEN
            EXECUTE format('UPDATE %I.onboarding_state SET status = %L WHERE status <> %L', v_pkg, 'completed', 'completed');
        END IF;
    END LOOP;
    RAISE NOTICE 'FIXTURES OK: Onboarding-Sektionen auf completed gesetzt.';
END $$;

COMMIT;
