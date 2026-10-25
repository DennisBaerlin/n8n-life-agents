-- ============================================================
-- Finance Package — Schema "finance" (Tabellen praefixlos; das Schema IST der Namespace)
-- Usage:   psql -U <user> -d <database> -f finance.tables_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS finance;

-- Required for exclusion constraint on overlapping date ranges
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ============================================================
-- PHASE-3a SCHEMA-EXTRAKTION (idempotent, beide Pfade korrekt — WS-A2/B2):
--   Fresh-DB: keine agent.finance_*-Objekte -> alle Guards no-op; die CREATE-Statements unten legen
--             den finance.*-Endzustand an.
--   Bestands-DB (lifeagents update): die Guards verschieben die ECHTEN Daten zuerst (SET SCHEMA + Praefix-
--             Strip) -> die CREATE ... IF NOT EXISTS / CREATE TYPE (duplicate_object) unten skippen, kein
--             Datenverlust. Owned Sequences ziehen mit ALTER TABLE SET SCHEMA automatisch um (PG-Doku).
--   ENUMs zuerst (nur SET SCHEMA, Name bleibt), dann Tabellen (SET SCHEMA + RENAME ohne finance_-Praefix);
--   Spalten referenzieren ENUMs per OID -> Move-Reihenfolge unkritisch. V005 droppt danach die agent.fn_*-Orphans.
-- ============================================================
DO $$
DECLARE e TEXT;
BEGIN
    FOREACH e IN ARRAY ARRAY[
        'account_type','account_status','schedule_unit','loan_status','payment_status',
        'property_status','insurance_status','goal_status','pension_type','pension_status',
        'transaction_category'
    ] LOOP
        IF to_regtype('agent.'||e) IS NOT NULL AND to_regtype('finance.'||e) IS NULL THEN
            EXECUTE format('ALTER TYPE agent.%I SET SCHEMA finance', e);
        END IF;
    END LOOP;
END $$;

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('finance_currencies','currencies'),
        ('finance_fx_rates','fx_rates'),
        ('finance_accounts','accounts'),
        ('finance_account_interest_rates','account_interest_rates'),
        ('finance_account_balances','account_balances'),
        ('finance_depot_holdings','depot_holdings'),
        ('finance_recurring_payments','recurring_payments'),
        ('finance_recurring_payment_skips','recurring_payment_skips'),
        ('finance_real_estate','real_estate'),
        ('finance_pension','pension'),
        ('finance_pension_statements','pension_statements'),
        ('finance_loans','loans'),
        ('finance_insurances','insurances'),
        ('finance_savings_goals','savings_goals'),
        ('finance_savings_goal_allocations','savings_goal_allocations'),
        ('finance_savings_plans','savings_plans'),
        ('finance_transactions','transactions'),
        ('finance_transaction_audit','transaction_audit')
    ) AS m(src, dst) LOOP
        IF to_regclass('agent.'||r.src) IS NOT NULL AND to_regclass('finance.'||r.dst) IS NULL THEN
            EXECUTE format('ALTER TABLE agent.%I SET SCHEMA finance', r.src);
            EXECUTE format('ALTER TABLE finance.%I RENAME TO %I', r.src, r.dst);
        END IF;
    END LOOP;
END $$;

-- ============================================================
-- ENUM TYPES
-- ============================================================

DO $$ BEGIN
    CREATE TYPE finance.account_type AS ENUM (
        'cash',
        'p2p',
        'stocks_depot',
        'crypto_depot',
        'fixed_deposit',
        'loan'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.account_status AS ENUM (
        'active',
        'closed'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.schedule_unit AS ENUM (
        'day',
        'week',
        'month',
        'year'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.loan_status AS ENUM (
        'active',
        'paused',
        'paid_off',
        'refinanced'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.payment_status AS ENUM (
        'active',
        'paused'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.property_status AS ENUM (
        'active',
        'sold'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.insurance_status AS ENUM (
        'active',
        'cancelled',
        'expired'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.goal_status AS ENUM (
        'active',
        'completed',
        'cancelled'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Pension / Altersvorsorge (German 3-pillar model). statutory = gesetzliche Rente,
-- occupational = betriebliche Altersvorsorge (bAV); riester/ruerup/private = 3rd pillar.
DO $$ BEGIN
    CREATE TYPE finance.pension_type AS ENUM (
        'statutory',
        'occupational',
        'riester',
        'ruerup',
        'private'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.pension_status AS ENUM (
        'active',
        'paused',
        'paid_out'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE finance.transaction_category AS ENUM (
        'disbursement',    -- Kreditauszahlung (+ Giro, - Kreditkonto)
        'loan_payment',    -- Kreditrate verlässt Girokonto (-)
        'principal',       -- Tilgungsanteil auf Kreditkonto (+)
        'settlement',      -- Kreditablösung / Umschuldungsausgleich (+)
        'buy',             -- Depot-Kauf (Settlement-Konto -, shares +)
        'sell',            -- Depot-Verkauf (Settlement-Konto +, shares -)
        'dividend',        -- Dividendenausschüttung (Settlement-Konto +)
        'interest',        -- Zinsgutschrift
        'transfer',        -- Überweisung zwischen eigenen Konten
        'fee',             -- Trade-unabhängige Gebühren (Depot-/Kontoführung); NICHT für Order-Gebühren
        'reconciliation',  -- Korrekturbuchung nach Saldo-Abgleich
        'other'            -- Sonstiges
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Migration: ensure new values exist on already-installed databases
ALTER TYPE finance.transaction_category ADD VALUE IF NOT EXISTS 'fee';
ALTER TYPE finance.transaction_category ADD VALUE IF NOT EXISTS 'reconciliation';
-- Bestandsuebernahme: Gegenbuchung zum synthetischen Kauf einer BEREITS gehaltenen Position
-- (fn_book_stock_buy existing_position) -> der Saldo des Verrechnungskontos bleibt unveraendert.
ALTER TYPE finance.transaction_category ADD VALUE IF NOT EXISTS 'position_takeover';

-- ============================================================
-- CURRENCIES (ISO-4217 dimension — nur tatsaechlich genutzte Waehrungen geseedet)
-- minor_unit = Anzahl Nachkommastellen (EUR=2, KRW=0) -> Single Source of Truth fuer
-- Anzeige-/Rundungsregeln (KRW wird ohne Nachkommastellen dargestellt). FK-Ziel aller
-- currency-Spalten -> ein Tippfehler ('EURO','won') wird zum lauten FK-Fehler statt zur
-- stillen Phantom-Waehrung, die kein Roll-up konvertieren kann.
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.currencies (
    code       char(3)  PRIMARY KEY,
    minor_unit smallint NOT NULL DEFAULT 2 CHECK (minor_unit BETWEEN 0 AND 4),
    symbol     varchar(8),
    name       varchar(50)
);

INSERT INTO finance.currencies (code, minor_unit, symbol, name) VALUES
    ('EUR', 2, '€', 'Euro')
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- FX RATES (base -> quote, datiert). EUR ist die Reporting-Basis.
-- rate = wie viele <quote>-Einheiten pro 1 <base>-Einheit (EUR-quotiert, EZB-Konvention:
-- z. B. base=EUR, quote=KRW, rate=1450 => 1 EUR = 1450 KRW). Umrechnung eines KRW-Betrags
-- nach EUR: betrag / rate.
-- Befuellt vom deterministischen Cron agent.finance.cron_refresh_fx_rates (HTTP -> Upsert, KEIN LLM);
-- Roll-up-Views konvertieren per As-of-Lookup (juengster as_of <= Stichtag). Datiert, damit auch
-- realisierte Event-Kurse (Cross-Currency-Transfer) nachschlagbar bleiben.
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.fx_rates (
    base_currency  char(3)        NOT NULL REFERENCES finance.currencies(code),
    quote_currency char(3)        NOT NULL REFERENCES finance.currencies(code),
    rate           numeric(20,10) NOT NULL CHECK (rate > 0),
    as_of          date           NOT NULL,
    source         varchar(50)    NOT NULL DEFAULT 'manual',
    updated_at     timestamptz    NOT NULL DEFAULT now(),
    PRIMARY KEY (base_currency, quote_currency, as_of)
);

CREATE INDEX IF NOT EXISTS idx_fx_rates_lookup
    ON finance.fx_rates (quote_currency, base_currency, as_of DESC);

-- ============================================================
-- MARKET PRICES (WS2b — Markt-Preis-Feed der Core-Advisor-Engine, datiert wie fx_rates)
-- Pro gehaltenem Depot-Symbol ein datierter Kurs in seiner NATIVE-Waehrung (= Holding-Waehrung);
-- die Roll-up-/Drift-Views rechnen den Marktwert (shares x price) und konvertieren via finance.fn_to_eur.
-- Befuellt vom deterministischen Cron agent.finance.cron_refresh_market_prices (Yahoo Finance v8/chart fuer
-- Aktien/ETF wie Portfolio Performance, CoinGecko fuer Krypto; HTTP -> finance.fn_upsert_market_prices, KEIN LLM). Symbol ist der stabile
-- Join-Key (immer vorhanden; isin NULL bei Krypto). PK (symbol, as_of) = idempotenter Tages-Upsert.
-- Schliesst zugleich die "Depot-Marktwert = Live-Injection"-Luecke (depot_holdings_overview kann kuenftig
-- echten Marktwert via juengstem as_of zeigen — Folge-Cleanup, BACKLOG).
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.market_prices (
    symbol     varchar(20)    NOT NULL,                 -- ticker (VWCE) oder crypto symbol (BTC) = Join-Key
    isin       varchar(12),                             -- NULL bei Krypto; nur sekundaerer Hint
    price      numeric(20,8)  NOT NULL CHECK (price > 0),-- Kurs je Anteil in <currency>; 8 NK fuer Krypto-Bruchteile
    currency   char(3)        NOT NULL DEFAULT 'EUR' REFERENCES finance.currencies(code),
    as_of      date           NOT NULL,
    source     varchar(50)    NOT NULL DEFAULT 'yahoo',
    updated_at timestamptz    NOT NULL DEFAULT now(),
    PRIMARY KEY (symbol, as_of)
);

CREATE INDEX IF NOT EXISTS idx_market_prices_lookup
    ON finance.market_prices (symbol, as_of DESC);

-- ============================================================
-- ZEIT-KONSTANTEN (Single Source of Truth fuer die Monats-Normalisierung)
-- fn_days_per_month: EIN Ort fuer den Durchschnitt 30.4375 (= 365.25/12). Genutzt von der
--   monthly_equivalent-GENERATED-Spalte UND fn_set_savings_goal (Rest-Monate) -> kein Drift.
-- fn_monthly_equivalent: normalisiert einen Betrag je (interval, unit) auf den Monat:
--   betrag * dpm / (interval * tage_pro_unit) mit day=1, week=7, month=dpm, year=365.25.
--   (Korrigiert zugleich die alte invertierte day/week-Rechnung: 25 EUR/Woche -> ~109/Monat, frueher 5,77.)
-- IMMUTABLE -> in STORED-GENERATED-Spalten nutzbar (die UDF-Sperre gilt nur fuer VIRTUAL-Spalten).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_days_per_month()
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT 30.4375::numeric $$;

CREATE OR REPLACE FUNCTION finance.fn_monthly_equivalent(
    p_amount numeric, p_interval int, p_unit finance.schedule_unit
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(
        p_amount * finance.fn_days_per_month()
        / (GREATEST(p_interval, 1) * CASE p_unit
              WHEN 'day'   THEN 1.0
              WHEN 'week'  THEN 7.0
              WHEN 'month' THEN finance.fn_days_per_month()
              WHEN 'year'  THEN 12.0 * finance.fn_days_per_month()
          END), 2);
$$;

-- 4-arg-Form: p_per_unit Termine je Einheit (feste Monatstage, z. B. Broker-Kalender 2/9/16/23 = 4 je Monat).
-- Eigene Overload statt DEFAULT-Parameter (der kollidierte mit der 3-arg-Form, an der Kredit/Versicherung haengen).
CREATE OR REPLACE FUNCTION finance.fn_monthly_equivalent(
    p_amount numeric, p_interval int, p_unit finance.schedule_unit, p_per_unit int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT finance.fn_monthly_equivalent(p_amount * GREATEST(p_per_unit, 1), p_interval, p_unit);
$$;

-- fn_period_months: Monate je Periode eines Rhythmus (day/week ueber fn_days_per_month normalisiert). Die EINE Adresse
-- fuer den Zins-Faktor einer Kreditrate (fn_loan_period_months, fn_loan_balance_at) und den Jahreswert.
CREATE OR REPLACE FUNCTION finance.fn_period_months(p_interval int, p_unit finance.schedule_unit)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(COALESCE(p_interval, 1), 1) * CASE p_unit
               WHEN 'day'   THEN 1.0 / finance.fn_days_per_month()
               WHEN 'week'  THEN 7.0 / finance.fn_days_per_month()
               WHEN 'month' THEN 1.0
               WHEN 'year'  THEN 12.0
           END;
$$;

-- fn_annual_equivalent (WP2 "Finanzen schlank"): Jahreswert eines Betrags je Abbuchung ohne Zwischenrundung
-- (monatlich 30 -> 360, jaehrlich 89 -> 89; p_per_unit = Termine je Einheit bei festen Monatstagen). Der Jahresbeitrag
-- einer Versicherung wird so aus der echten Abbuchung abgeleitet statt gespeichert (Views active_insurances,
-- loan_overview.initial_principal_rate). Bei nicht-jaehrlichem Rhythmus kann er um Cent vom genannten Jahresbeitrag
-- abweichen (100/Jahr monatlich = 8,33 je Abbuchung = 99,96): die Abbuchung ist die Wahrheit.
CREATE OR REPLACE FUNCTION finance.fn_annual_equivalent(
    p_amount numeric, p_interval int, p_unit finance.schedule_unit, p_per_unit int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(p_amount * GREATEST(COALESCE(p_per_unit, 1), 1) * 12.0 / finance.fn_period_months(p_interval, p_unit), 2);
$$;

-- fn_insurance_period_amount: Beitrag JE ABBUCHUNG aus einer genannten Jahrespraemie (nur wenn der Nutzer den
-- Jahresbeitrag nennt; sonst kommt der Betrag je Abbuchung roh). Exakte Umkehrung von fn_monthly_equivalent
-- (365,25-Tage-Basis): day annual*n/365.25, week annual*n*7/365.25, month annual*n/12, year annual*n.
-- RUECKGABE: POSITIVER Betrag (2 Nachkommastellen). IM INIT (WP2, vorher R__): finance:V027 vergleicht im Pre-flight
-- dagegen, und V-Migrationen laufen vor allen R__-fns.
CREATE OR REPLACE FUNCTION finance.fn_insurance_period_amount(
    p_annual numeric, p_interval int, p_unit finance.schedule_unit
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(
        p_annual * GREATEST(COALESCE(p_interval, 1), 1) * CASE p_unit
            WHEN 'day'   THEN 1.0
            WHEN 'week'  THEN 7.0
            WHEN 'month' THEN finance.fn_days_per_month()
            WHEN 'year'  THEN 365.25
        END / 365.25, 2);
$$;

-- fn_schedule_occurrences (WP2): das EINE Faelligkeitsraster eines Rhythmus -- alle Termine d mit
-- p_from <= d <= p_until und d >= Anker. Monat: Tag aus dom (-1 Monatsletzter, -2 vorletzter, NULL = Tag des Ankers mit
-- Monatsend-Clamping gegen den Anker, sonst fester Tag) bzw. jeder Tag aus p_days (feste Monatstage). Rein und
-- IMMUTABLE (explizite timestamp-Casts + make_interval: keine Zeitzonen-Abhaengigkeit), LANGUAGE sql ohne STRICT/SET
-- -> inlinebar. Gerufen von fn_recurring_due_open (Scheduler, Gueltigkeit/Status/gebucht dort) und fn_loan_balance_at
-- (Restschuld-Vorschau) -> Erinnerung und Vorschau rechnen dasselbe Raster. IM INIT, weil Views es (indirekt) nutzen.
CREATE OR REPLACE FUNCTION finance.fn_schedule_occurrences(
    p_anchor date, p_interval int, p_unit finance.schedule_unit, p_dom smallint, p_days smallint[],
    p_from date, p_until date
) RETURNS SETOF date LANGUAGE sql IMMUTABLE AS $$
    WITH a AS (
        SELECT p_anchor::timestamp AS f,
               GREATEST(COALESCE(p_interval, 1), 1) AS n,
               EXTRACT(YEAR FROM age(p_until::timestamp, p_anchor::timestamp))::int * 12
               + EXTRACT(MONTH FROM age(p_until::timestamp, p_anchor::timestamp))::int AS m
    )
    SELECT o.d FROM (
        SELECT gs::date AS d
        FROM a, generate_series(a.f, p_until::timestamp, make_interval(days => a.n)) gs
        WHERE p_unit = 'day'
        UNION ALL
        SELECT gs::date
        FROM a, generate_series(a.f, p_until::timestamp, make_interval(days => a.n * 7)) gs
        WHERE p_unit = 'week'
        UNION ALL
        SELECT (CASE
                  WHEN p_dom IN (-1, -2) THEN date_trunc('month', a.f) + make_interval(months => k * a.n + 1, days => p_dom)
                  WHEN p_dom IS NULL     THEN a.f + make_interval(months => k * a.n)
                  ELSE date_trunc('month', a.f) + make_interval(months => k * a.n, days => p_dom - 1)
                END)::date
        FROM a, generate_series(0, a.m / a.n + 1) k
        WHERE p_unit = 'month' AND p_days IS NULL
        UNION ALL
        SELECT (date_trunc('month', a.f) + make_interval(months => k * a.n, days => dd - 1))::date
        FROM a, generate_series(0, a.m / a.n + 1) k, unnest(p_days) dd
        WHERE p_unit = 'month' AND p_days IS NOT NULL
        UNION ALL
        SELECT (a.f + make_interval(years => k * a.n))::date
        FROM a, generate_series(0, (a.m / 12) / a.n + 1) k
        WHERE p_unit = 'year'
    ) o
    WHERE o.d >= p_anchor AND o.d >= p_from AND o.d <= p_until;
$$;

-- fn_loan_balance_at (WP2): voraussichtliche Restschuld zum Zieldatum -- rein, alle Eingaben als Argumente.
--   p_balance  = Restschuld heute (positiv), p_rate_pct = Jahreszins, p_segments = die Raten-Glieder der Kette
--   [{anchor, interval, unit, dom, days, valid_from, valid_to (exklusiv), amount (positiv)}], p_after = juengster
--   erledigter (gebuchter/uebersprungener) Faelligkeitstermin der Kette (NULL = keiner), p_target, p_today.
--   Rechnet jeden Rasterpunkt d mit d > p_after, valid_from <= d < valid_to, d <= p_target in Datumsfolge: Zins =
--   fn_loan_monthly_interest(Restschuld, Zins, fn_period_months) (dieselbe Formel + Rundung wie jede Buchung), Tilgung =
--   Rate - Zins. Faellige, noch nicht gebuchte Raten zaehlen mit; Annahme: gleicher Zins, keine Sondertilgung.
--   RUECKGABE: Restschuld (2 Nachkommastellen), 0 sobald getilgt; NULL bei Ziel <= heute, ohne Segmente (pausiert /
--   ohne Rate) oder ueber 2.400 Termine (Iterationsdeckel). IM INIT, weil loan_overview (R__finance_views laeuft vor
--   allen R__fn_*) sie nutzt.
CREATE OR REPLACE FUNCTION finance.fn_loan_balance_at(
    p_balance numeric, p_rate_pct numeric, p_segments jsonb, p_after date, p_target date, p_today date
) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_bal NUMERIC := p_balance;
    v_n   INT := 0;
    r     RECORD;
BEGIN
    IF p_target IS NULL OR p_today IS NULL OR p_target <= p_today OR p_balance IS NULL
       OR p_segments IS NULL OR jsonb_typeof(p_segments) <> 'array' OR jsonb_array_length(p_segments) = 0 THEN
        RETURN NULL;
    END IF;
    IF v_bal <= 0 THEN
        RETURN 0;
    END IF;
    FOR r IN
        SELECT o.d,
               (s->>'amount')::numeric AS amt,
               finance.fn_period_months((s->>'interval')::int, (s->>'unit')::finance.schedule_unit) AS months
        FROM jsonb_array_elements(p_segments) s
        CROSS JOIN LATERAL finance.fn_schedule_occurrences(
            (s->>'anchor')::date, (s->>'interval')::int, (s->>'unit')::finance.schedule_unit,
            NULLIF(s->>'dom', '')::smallint,
            CASE WHEN jsonb_typeof(s->'days') = 'array'
                 THEN ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(s->'days') x) END,
            GREATEST((s->>'valid_from')::date, p_after + 1), p_target) o(d)
        WHERE NULLIF(s->>'valid_to', '') IS NULL OR o.d < (s->>'valid_to')::date
        ORDER BY o.d
    LOOP
        v_n := v_n + 1;
        IF v_n > 2400 THEN
            RETURN NULL;
        END IF;
        v_bal := v_bal - (r.amt - finance.fn_loan_monthly_interest(v_bal, p_rate_pct, r.months));
        IF v_bal <= 0 THEN
            RETURN 0;
        END IF;
    END LOOP;
    RETURN ROUND(v_bal, 2);
END;
$$;

-- fn_valid_schedule_days: Domaene einer Liste fester Monatstage (recurring_payments.schedule_days_of_month,
-- accounts.plan_execution_days) -- NULL oder leer, sonst eindimensional, ohne NULL, jeder Tag 1-28 (29/30/31
-- overflowen kurze Monate, wie fn_valid_schedule_dom), streng aufsteigend (kanonisch: eine Liste = eine Schreibweise).
-- IMMUTABLE fn statt Inline-CHECK, weil "streng aufsteigend" eine Unterabfrage braucht (im CHECK verboten).
CREATE OR REPLACE FUNCTION finance.fn_valid_schedule_days(p_days smallint[])
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_days IS NULL
        OR cardinality(p_days) = 0
        OR (array_ndims(p_days) = 1
            AND array_position(p_days, NULL) IS NULL
            AND 1 <= ALL (p_days) AND 28 >= ALL (p_days)
            AND p_days = ARRAY(SELECT DISTINCT d FROM unnest(p_days) d ORDER BY d));
$$;

-- fn_loan_monthly_interest (Audit Paket 3): die EINE Zinsformel einer Kreditrate = positive Restschuld *
-- Jahreszins / 1200 * Monate der Raten-Periode (Default 1 = Monatszins), einmal auf Cent gerundet. Genutzt von
-- der Cashflow-Klassifikation (finance.recurring_cashflow_classified: Zins = Konsum, Rest = Tilgung; monatlich),
-- loan_overview und fn_get_loan_payment_split (HITL-Vorschau + Buchung, Perioden-Faktor der Rate) -> Uebersicht,
-- Karte und Buchung rechnen gleich. IM INIT (nicht R__), weil R__finance_views vor den R__fn_*-Dateien laeuft.
CREATE OR REPLACE FUNCTION finance.fn_loan_monthly_interest(p_remaining numeric, p_annual_rate_pct numeric,
                                                            p_months numeric DEFAULT 1)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(GREATEST(COALESCE(p_remaining, 0), 0) * COALESCE(p_annual_rate_pct, 0) / 1200.0
                 * COALESCE(p_months, 1), 2);
$$;

-- fn_interest_eligible_account_type (Phase Z WS-Z4): die EINE Adresse der zins-faehigen Kontotypen
-- (Allowlist cash/fixed_deposit/p2p; p2p = z. B. Bondora Go & Grow, zinstragend). Sicher-per-Default: ein
-- kuenftiger account_type-ENUM-Wert ist ohne Eintrag hier zinslos. Genutzt von fn_interest_due_open (Filter),
-- fn_set_account_interest / fn_book_interest_occurrence ({ok:false}-Guard) UND dem Backstop-Trigger
-- trg_finance_reject_interest_rate_ineligible (s. u.). IM INIT definiert (nicht R__), weil der Init-Trigger
-- UND die LANGUAGE-sql-fn fn_interest_due_open sie referenzieren -> sie muss vor der R-Phase existieren
-- (gleiches Muster wie fn_monthly_equivalent fuer die GENERATED-Spalte oben).
CREATE OR REPLACE FUNCTION finance.fn_interest_eligible_account_type(p_type finance.account_type)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_type IN ('cash', 'fixed_deposit', 'p2p');
$$;

-- fn_loan_is_outstanding (Audit Paket 2, Punkt 10): die EINE Schulden-Definition -- ein Kredit ist offene Schuld,
-- solange er active ODER paused ist (pausiert = Raten ausgesetzt, Restschuld besteht weiter). Vorher zaehlte ein
-- pausierter Kredit im Vermoegen (Kreditkonto-Saldo), fehlte aber in loan_summary (-> Advisor debt_total) und in
-- real_estate_overview.net_equity. Genutzt von loan_summary, real_estate_overview, fn_liability_register,
-- fn_sell_real_estate. IM INIT, weil die Views (R__finance_views sortiert vor R__fn_*) sie referenzieren.
CREATE OR REPLACE FUNCTION finance.fn_loan_is_outstanding(p_status finance.loan_status)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_status IN ('active', 'paused');
$$;

-- ============================================================
-- ZINS-RASTER (die EINE Quelle der Gutschrift-Termine; Live-Befund 2026-10-24: Kalender-Raster)
--   fn_interest_grid_point(anchor, k, n, unit, dom) = der k-te Rasterpunkt (k >= 0) eines Zins-Regimes mit Anker
--     anchor. fn_interest_due_open zaehlt die Vorkommen damit auf, fn_interest_period_start / fn_interest_next_period_end
--     suchen darin -> Faelligkeit, Periodenbeginn und die "Erste Gutschrift" der Karte rechnen dasselbe Raster.
--   KALENDER-RASTER, wenn dom = -1 UND (unit = 'year' ODER unit = 'month' mit n in {1,2,3,4,6,12}): Rasterpunkte sind
--     die Kalender-Enden -- Monatsende; alle n Monate die Enden der Kalender-Monate mit Monatszahl mod n = 0
--     (Quartal 31.03./30.06./30.09./31.12., Halbjahr 30.06./31.12.); 'year' = 31.12. alle n Jahre. Punkt k=0 ist das
--     letzte Kalender-Ende im oder vor dem Anker-Monat (kann vor dem Anker liegen; der Anker selbst ist nie eine
--     Gutschrift -> die erste Periode ist eine Teilperiode ab Start). Vorher verankerte das Raster am Start-Monat
--     (Start 24.10., vierteljaehrlich -> 31.10./31.01. statt 31.12./31.03.; 'year' ignorierte dom ganz).
--   ANKER-RASTER sonst (unveraendert): day/week = Anker + k*n Tage/Wochen; year = Jahrestag des Ankers; month mit
--     dom NULL = Anker-Tag, mit festem Tag = dieser Tag im Anker-Monat + k*n, mit dom -1 und n ausserhalb {1,2,3,4,6,12}
--     = Monatsende des Anker-Monats + k*n (Altzeilen; neue Zeilen lehnt fn_interest_schedule_reason ab).
--   fn_interest_grid_index(anchor, d, ...) = geschaetzter Index k des Rasterpunkts bei Datum d (Suchfenster der
--     Aufrufer: idx-2 .. idx+2, der Schaetzfehler ist hoechstens 1).
--   Init (nicht R__): die LANGUAGE-sql-fn fn_interest_due_open referenziert sie und liegt alphabetisch davor.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_grid_is_calendar(p_n int, p_unit finance.schedule_unit, p_dom int)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_dom = -1 AND (p_unit = 'year' OR (p_unit = 'month' AND 12 % GREATEST(p_n, 1) = 0));
$$;

CREATE OR REPLACE FUNCTION finance.fn_interest_grid_point(
    p_anchor date, p_k int, p_n int, p_unit finance.schedule_unit, p_dom int
) RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN finance.fn_interest_grid_is_calendar(p_n, p_unit, p_dom) THEN (
            -- Monatsindex M = Jahr*12 + (Monat-1); Kalender-Ende, wenn (M+1) mod m = 0 (m = n bzw. 12 bei 'year').
            WITH c AS (
                SELECT (EXTRACT(YEAR FROM p_anchor)::int * 12 + EXTRACT(MONTH FROM p_anchor)::int - 1) AS a,
                       CASE p_unit WHEN 'year' THEN 12 ELSE GREATEST(p_n, 1) END AS m,
                       CASE p_unit WHEN 'year' THEN 12 * GREATEST(p_n, 1) ELSE GREATEST(p_n, 1) END AS step
            ), p AS (
                SELECT (c.a - ((c.a + 1) % c.m)) + p_k * c.step AS mi FROM c
            )
            SELECT (make_date(p.mi / 12, p.mi % 12 + 1, 1) + interval '1 month' - interval '1 day')::date FROM p)
        WHEN p_unit = 'day'  THEN p_anchor + p_k * GREATEST(p_n, 1)
        WHEN p_unit = 'week' THEN p_anchor + p_k * GREATEST(p_n, 1) * 7
        WHEN p_unit = 'year' THEN (p_anchor + (p_k * GREATEST(p_n, 1) || ' years')::interval)::date
        WHEN p_dom = -1 THEN
            (date_trunc('month', p_anchor) + (p_k * GREATEST(p_n, 1) || ' months')::interval
             + interval '1 month' - interval '1 day')::date
        WHEN p_dom IS NULL THEN (p_anchor + (p_k * GREATEST(p_n, 1) || ' months')::interval)::date
        ELSE (date_trunc('month', p_anchor) + (p_k * GREATEST(p_n, 1) || ' months')::interval
              + ((p_dom - 1) || ' days')::interval)::date
    END;
$$;

CREATE OR REPLACE FUNCTION finance.fn_interest_grid_index(
    p_anchor date, p_date date, p_n int, p_unit finance.schedule_unit, p_dom int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(0, CASE
        WHEN finance.fn_interest_grid_is_calendar(p_n, p_unit, p_dom) THEN
            ((EXTRACT(YEAR FROM p_date)::int * 12 + EXTRACT(MONTH FROM p_date)::int)
             - (EXTRACT(YEAR FROM p_anchor)::int * 12 + EXTRACT(MONTH FROM p_anchor)::int))
            / (CASE p_unit WHEN 'year' THEN 12 ELSE 1 END * GREATEST(p_n, 1))
        WHEN p_unit = 'day'  THEN (p_date - p_anchor) / GREATEST(p_n, 1)
        WHEN p_unit = 'week' THEN (p_date - p_anchor) / (7 * GREATEST(p_n, 1))
        WHEN p_unit = 'year' THEN (EXTRACT(YEAR FROM p_date) - EXTRACT(YEAR FROM p_anchor))::int / GREATEST(p_n, 1)
        ELSE ((EXTRACT(YEAR FROM p_date) - EXTRACT(YEAR FROM p_anchor))::int * 12
              + (EXTRACT(MONTH FROM p_date) - EXTRACT(MONTH FROM p_anchor))::int) / GREATEST(p_n, 1)
    END);
$$;

-- fn_interest_period_start (WP-2, die EINE Tiling-Quelle fuer den Perioden-START): groesster Rasterpunkt
-- (fn_interest_grid_point) STRIKT < period_end, geclamped auf den Anker. Rein Schedule-abgeleitet (nie aus gebuchten/
-- uebersprungenen Tx) -> skip-invariant; aufeinanderfolgende Perioden kacheln lueckenlos period_start(k+1) ==
-- period_end(k), auch fuer TEILPERIODEN (Regime-Ende/Kadenzwechsel nicht auf dem Raster; Audit Paket 2) und die erste
-- Teilperiode eines Kalender-Rasters (Start 24.10., Quartal -> 24.10..31.12.). Behebt historisch den dom=-1-Overlap
-- (Grenze aus Anker + Index, nie aus dem gerollten period_end subtrahiert; QuantLib). BEIDE Zins-fns rufen sie
-- (fn_interest_due_open je Zeile, fn_interest_amount_due skalar) mit ihren Regime-Parametern; den Schutz vor
-- Doppelverzinsung nach einem Raster-Wechsel auf Bestandsdaten (GREATEST mit der juengsten erledigten Periode)
-- traegt fn_interest_effective_period_start (die eine Regel fuer due_open und amount_due).
CREATE OR REPLACE FUNCTION finance.fn_interest_period_start(
    p_anchor date, p_period_end date, p_n int, p_unit finance.schedule_unit, p_dom int
) RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(p_anchor, (
        SELECT max(b)
        FROM (SELECT finance.fn_interest_grid_point(p_anchor, k, p_n, p_unit, p_dom) AS b
              FROM generate_series(GREATEST(0, finance.fn_interest_grid_index(p_anchor, p_period_end, p_n, p_unit, p_dom) - 2),
                                   finance.fn_interest_grid_index(p_anchor, p_period_end, p_n, p_unit, p_dom) + 2) k) g
        WHERE g.b < p_period_end));
$$;

-- fn_interest_next_period_end: der erste Rasterpunkt NACH p_after (und nach dem Anker) -- die "Erste Gutschrift" der
-- HITL-Karte (fn_account_interest_defaults / fn_interest_rate_preview), aus demselben Raster wie die Faelligkeit.
CREATE OR REPLACE FUNCTION finance.fn_interest_next_period_end(
    p_anchor date, p_after date, p_n int, p_unit finance.schedule_unit, p_dom int
) RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT min(b)
    FROM (SELECT finance.fn_interest_grid_point(p_anchor, k, p_n, p_unit, p_dom) AS b
          FROM generate_series(GREATEST(0, finance.fn_interest_grid_index(p_anchor, GREATEST(p_after, p_anchor), p_n, p_unit, p_dom) - 2),
                               finance.fn_interest_grid_index(p_anchor, GREATEST(p_after, p_anchor), p_n, p_unit, p_dom) + 3) k) g
    WHERE g.b > GREATEST(p_after, p_anchor);
$$;

-- fn_interest_value_date: Gutschrift-Datum eines Periodenendes -- period_end selbst, mit posting_day_of_month
-- (Arrears) der n-te Tag im Folgemonat. EINE Formel fuer fn_interest_due_open und die Karte.
CREATE OR REPLACE FUNCTION finance.fn_interest_value_date(p_period_end date, p_pdom smallint)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_pdom IS NULL THEN p_period_end
                ELSE (date_trunc('month', p_period_end) + interval '1 month' + ((p_pdom - 1) || ' days')::interval)::date
           END;
$$;


-- ============================================================
-- ACCOUNTS
-- All account types in one table.
-- fixed_deposit_* columns are only populated for account_type = 'fixed_deposit'.
-- Depot accounts (stocks_depot, crypto_depot) have positions in finance_depot_holdings.
-- settlement_account_id links a depot to its cash settlement account.
-- loan accounts carry negative balances (Restschuld), auto-maintained by trigger.
-- Depot accounts (stocks_depot, crypto_depot) carry no transactions; their balance is always 0.
-- Depot value = SUM(shares × live_price) from finance_depot_holdings, injected at query time.
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.accounts (
    id                          serial PRIMARY KEY,
    name                        varchar(100) NOT NULL,
    account_type                finance.account_type NOT NULL,
    bank                        varchar(100),
    account_number              varchar(50),            -- IBAN, depot number, P2P account ID — no format enforced
    settlement_account_id       int REFERENCES finance.accounts(id), -- depot only: linked cash account
    owner_person_id             text,                   -- Multi-Member: Eigentümer-Person, das EINZIGE Inhaber-Feld (Slug aus family; NULL=Haushalt/gemeinsam); FK unten. WS-4: Freitext-account_holder abgelöst.
    currency                    char(3) NOT NULL DEFAULT 'EUR',
    status                      finance.account_status NOT NULL DEFAULT 'active',
    fixed_deposit_maturity_date date,                   -- only for fixed_deposit
    fixed_deposit_auto_renew    boolean,                -- only for fixed_deposit
    last_reconciled_balance     numeric(12,2),          -- last user-confirmed real-world balance (reconciliation playbook)
    last_reconciled_at          date,                   -- date of that confirmation
    opening_balance_date        date,                   -- Stichtag des beim Anlegen genannten Saldos (fn_create_account); Vorkommen davor stecken im Saldo (fn_recurring_valid_from)
    -- WS-0b (estate): Nachlass-relevante Konto-Attribute (additiv nullable, Init-only, KEIN V).
    -- ownership = rechtliche Kontoinhaberschaft: single=Einzelkonto, joint_or=Oder-Konto (Ueberlebender
    --   behaelt vollen Zugriff), joint_and=Und-Konto (nach Tod verfuegungsbeschraenkt). NULL=nicht erfasst.
    -- has_transmortal_poa = existiert eine transmortale Bankvollmacht (ueber den Tod hinaus)? Zugriffs-
    --   Beschleuniger fuer die Erben. NULL=unbekannt (bewusst KEIN DEFAULT false — im Register ehrlich offen).
    -- estate liest beide ueber finance.fn_account_register() (Oberflaeche A); finance besitzt die Spalten.
    ownership                   text,
    has_transmortal_poa         boolean,
    notes                       text,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    -- Depot accounts MUST have a settlement (Verrechnungs-) account; other types must not require one.
    CONSTRAINT finance_accounts_depot_needs_settlement CHECK (
        account_type NOT IN ('stocks_depot', 'crypto_depot')
        OR settlement_account_id IS NOT NULL
    ),
    -- WS-0b: geschlossene ownership-Liste = struktureller Backstop (die Tool-Description fuehrt den Agenten).
    CONSTRAINT finance_accounts_ownership_chk CHECK (
        ownership IS NULL OR ownership IN ('single', 'joint_or', 'joint_and')
    )
);

-- Migration: add reconciliation columns on already-installed databases
ALTER TABLE finance.accounts ADD COLUMN IF NOT EXISTS last_reconciled_balance numeric(12,2);
ALTER TABLE finance.accounts ADD COLUMN IF NOT EXISTS last_reconciled_at date;
-- Migration (Eindeutigkeit 2026-10-21): Stichtag des Eroeffnungssaldos, additiv nullable (Init-only, KEIN V).
ALTER TABLE finance.accounts ADD COLUMN IF NOT EXISTS opening_balance_date date;

-- Migration (WS-0b estate): ownership + has_transmortal_poa additiv/idempotent auf Bestands-DBs (Init-only,
-- KEIN V — rein additiv nullable). Der ownership-CHECK (geschlossene Liste) ist der strukturelle Backstop.
ALTER TABLE finance.accounts ADD COLUMN IF NOT EXISTS ownership text;
ALTER TABLE finance.accounts ADD COLUMN IF NOT EXISTS has_transmortal_poa boolean;
DO $$ BEGIN
    ALTER TABLE finance.accounts DROP CONSTRAINT IF EXISTS finance_accounts_ownership_chk;
    ALTER TABLE finance.accounts ADD CONSTRAINT finance_accounts_ownership_chk
        CHECK (ownership IS NULL OR ownership IN ('single', 'joint_or', 'joint_and'));
END $$;

-- Monats-Check WP-B: Kontonummer/IBAN ist die eindeutige Zuordnung eines Kontoauszugs zum Konto.
-- fn_normalize_account_number = die EINE Normalform (Grossbuchstaben, ohne Leerzeichen, leer -> NULL); Init-Baseline-
-- Helfer (CHECK-gekoppelt, kein R__: ein CREATE OR REPLACE einer constraint-gekoppelten fn prueft Bestand nicht neu).
CREATE OR REPLACE FUNCTION finance.fn_normalize_account_number(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(upper(regexp_replace(p, '\s', '', 'g')), '');
$$;
-- fn_iban_valid (Paket DB-ist-das-Gesetz S7): IBAN-Pruefziffer ISO 13616 mod 97. TRUE, wenn KEINE IBAN-Form
-- (Depotnummer, P2P-Id, maskierte Karte, NULL) ODER IBAN mit stimmender Pruefziffer; FALSE nur fuer eine verlesene/
-- vertippte IBAN. Init-Baseline-Helfer wie oben (gekoppelt an CHECK finance_accounts_iban_chk, V021). Konsumenten:
-- fn_create_account, fn_set_account, fn_statement_prepare (verlesene Kopf-IBAN -> unreadable statt "neues Konto").
CREATE OR REPLACE FUNCTION finance.fn_iban_valid(p text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n      TEXT := upper(regexp_replace(COALESCE(p, ''), '\s', '', 'g'));
    v_r      TEXT;
    v_digits TEXT := '';
    v_c      TEXT;
BEGIN
    IF v_n !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' OR v_n ~ 'XXX' THEN   -- keine IBAN-Form bzw. mit X maskiert
        RETURN TRUE;
    END IF;
    v_r := substr(v_n, 5) || substr(v_n, 1, 4);   -- Laendercode + Pruefziffer ans Ende
    FOREACH v_c IN ARRAY regexp_split_to_array(v_r, '') LOOP
        v_digits := v_digits || CASE WHEN v_c ~ '[0-9]' THEN v_c ELSE (ascii(v_c) - 55)::text END;   -- A=10 .. Z=35
    END LOOP;
    RETURN (v_digits::numeric % 97) = 1;
END;
$$;
-- Idempotente Bereinigung VOR CHECK/Index (Muster interest_period_end): normalisieren; bei Dubletten unter aktiven
-- Konten behaelt das aelteste die Nummer, die anderen werden geleert (NOTICE) — der naechste Kontoauszug lernt sie
-- neu. Kein Abbruch von `lifeagents update`.
DO $$
DECLARE v_n INT;
BEGIN
    UPDATE finance.accounts SET account_number = finance.fn_normalize_account_number(account_number)
    WHERE account_number IS DISTINCT FROM finance.fn_normalize_account_number(account_number);
    UPDATE finance.accounts a SET account_number = NULL
    WHERE a.status = 'active' AND a.account_number IS NOT NULL
      AND EXISTS (SELECT 1 FROM finance.accounts o
                  WHERE o.status = 'active' AND o.account_number = a.account_number AND o.id < a.id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
        RAISE NOTICE 'finance: % Konto/Konten mit doppelter Kontonummer geleert (aeltestes behaelt sie).', v_n;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'finance_accounts_number_normalized_chk') THEN
        ALTER TABLE finance.accounts ADD CONSTRAINT finance_accounts_number_normalized_chk
            CHECK (account_number IS NULL OR account_number = finance.fn_normalize_account_number(account_number));
    END IF;
END $$;
-- Eindeutig nur unter AKTIVEN Konten (ein geschlossenes Konto gibt seine Nummer frei).
CREATE UNIQUE INDEX IF NOT EXISTS finance_accounts_number_active_uq
    ON finance.accounts (account_number)
    WHERE account_number IS NOT NULL AND status = 'active';

-- Migration: enforce depot-needs-settlement on already-installed databases
DO $$ BEGIN
    ALTER TABLE finance.accounts
        DROP CONSTRAINT IF EXISTS finance_accounts_depot_needs_settlement;
    ALTER TABLE finance.accounts
        ADD CONSTRAINT finance_accounts_depot_needs_settlement CHECK (
            account_type NOT IN ('stocks_depot', 'crypto_depot')
            OR settlement_account_id IS NOT NULL
        );
END $$;

-- ============================================================
-- ACCOUNT INTEREST RATES
-- Rate history per account. Both rate and crediting schedule can change independently.
-- schedule_interval + schedule_unit replace a rigid ENUM (e.g. interval=3, unit=month = quarterly crediting).
-- schedule_day_of_month: 1–28 = specific day, -1 = last day of month (no -2 here: interest grid), NULL = relative to first credit.
-- Exclusion constraint prevents overlapping validity periods per account.
-- Zins-Ausbau (Folgephase WS-5c): day_count_convention = Tageszaehl-Methode je Rate-Zeile (kohaesiv mit
--   Satz+Schedule+Historie), bestimmt den taggenauen Perioden-Anteil in fn_interest_day_fraction
--   (30E/360 deutsche Methode, ACT/365, ACT/360). posting_day_of_month gesetzt = Arrears-Gutschrift
--   (value_date = posting_day_of_month im Monat NACH dem Perioden-Ende; NULL = Gutschrift am Perioden-Ende).
--   auto_post = taegliche/woechentliche Auto-Buchung im Cron ohne HITL (Default per Kadenz, pro Konto
--   ueberschreibbar). Methode/auto_post werden bei der Anlage aus dem Kontotyp/der Kadenz VORGESCHLAGEN
--   (fn_interest_default_convention / fn_interest_auto_post_default), im HITL-Gate mit Grund gezeigt.
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.account_interest_rates (
    id                    serial PRIMARY KEY,
    account_id            int NOT NULL REFERENCES finance.accounts(id) ON DELETE CASCADE,
    annual_rate           numeric(6,4) NOT NULL,        -- e.g. 4.5000 = 4.5% p.a.
    schedule_interval     smallint NOT NULL DEFAULT 1,  -- every N units
    schedule_unit         finance.schedule_unit NOT NULL, -- unit (month = monthly crediting)
    schedule_day_of_month smallint,                     -- specific day; -1 = last day
    day_count_convention  text NOT NULL DEFAULT '30E/360', -- '30E/360' | 'ACT/365' | 'ACT/360'; CHECK below
    posting_day_of_month  smallint,                     -- set => Arrears: credit on this day of the month AFTER period_end
    auto_post             boolean,                      -- true => Cron books without HITL (daily/weekly default)
    valid_from            date NOT NULL,
    valid_to              date,                         -- NULL = currently active
    CONSTRAINT finance_account_interest_rates_no_overlap
        EXCLUDE USING gist (
            account_id WITH =,
            daterange(valid_from, coalesce(valid_to, '9999-12-31'::date), '[)') WITH &&
        )
);

-- Migration (Zins-Ausbau): die drei Zins-Spalten additiv/idempotent auf Bestands-DBs (Init-only, KEINE
-- V-Migration — rein additiv, nullable bzw. NOT-NULL-DEFAULT). Der day_count-CHECK ist der strukturelle
-- Backstop (die fn_interest_default_convention liefert einen gueltigen Wert; ein Direktzugriff mit
-- Tippfehler scheitert hart statt still). DROP+ADD = idempotent je Apply.
ALTER TABLE finance.account_interest_rates ADD COLUMN IF NOT EXISTS day_count_convention text NOT NULL DEFAULT '30E/360';
ALTER TABLE finance.account_interest_rates ADD COLUMN IF NOT EXISTS posting_day_of_month smallint;
ALTER TABLE finance.account_interest_rates ADD COLUMN IF NOT EXISTS auto_post boolean;
DO $$ BEGIN
    ALTER TABLE finance.account_interest_rates DROP CONSTRAINT IF EXISTS finance_air_day_count_chk;
    ALTER TABLE finance.account_interest_rates ADD CONSTRAINT finance_air_day_count_chk
        CHECK (day_count_convention IN ('30E/360', 'ACT/365', 'ACT/360'));
END $$;

-- ============================================================
-- fn_interest_regimes (Audit Paket 2, Punkt 5) -- die EINE Quelle der Zins-Kadenz eines Kontos.
--   Ein Regime = zusammenhaengender Lauf von account_interest_rates-Zeilen mit GLEICHER Kadenz (schedule_interval,
--   schedule_unit, schedule_day_of_month); ein reiner Satzwechsel bleibt im Regime (Raster unveraendert, Satz-Mischung
--   macht fn_interest_rate_segments). Ein KADENZWECHSEL beginnt ein neues Regime mit Anker = sein Start; das alte
--   endet dort (regime_end = Start des neuen; NULL = laufend). posting_day_of_month/auto_post aus der juengsten Zeile
--   des Regimes. Bewusst KEIN Bruch an Datumsluecken: eine Luecke zwischen Zeilen ist Datenkorruption und bleibt in
--   fn_interest_amount_due fail-closed (RAISE) statt still zinslos.
--   Gelesen von fn_interest_due_open (Faelligkeiten je Regime; keine Gutschrift am Wechseltag) und
--   fn_interest_amount_due (Regime des letzten Periodentags) -> beide nutzen dieselbe Kadenz.
--   Init (nicht R__), weil die LANGUAGE-sql-fn fn_interest_due_open sie referenziert und alphabetisch VOR ihr liegt.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_regimes(p_account_id int)
RETURNS TABLE(regime_start date, regime_end date, anchor date, n smallint, unit finance.schedule_unit,
              dom smallint, pdom smallint, auto_post boolean)
LANGUAGE sql STABLE AS $$
    WITH r AS (
        SELECT valid_from, valid_to, schedule_interval, schedule_unit, schedule_day_of_month,
               posting_day_of_month, COALESCE(auto_post, false) AS ap,
               CASE WHEN lag(schedule_interval) OVER w IS NULL
                      OR (lag(schedule_interval) OVER w, lag(schedule_unit) OVER w, lag(schedule_day_of_month) OVER w)
                         IS DISTINCT FROM (schedule_interval, schedule_unit, schedule_day_of_month)
                    THEN 1 ELSE 0 END AS brk
        FROM finance.account_interest_rates
        WHERE account_id = p_account_id
        WINDOW w AS (ORDER BY valid_from)
    ), g AS (
        SELECT *, sum(brk) OVER (ORDER BY valid_from) AS grp FROM r
    )
    SELECT min(valid_from),
           (array_agg(valid_to ORDER BY valid_from DESC))[1],
           min(valid_from),
           (array_agg(schedule_interval ORDER BY valid_from))[1],
           (array_agg(schedule_unit ORDER BY valid_from))[1],
           (array_agg(schedule_day_of_month ORDER BY valid_from))[1],
           (array_agg(posting_day_of_month ORDER BY valid_from DESC))[1],
           (array_agg(ap ORDER BY valid_from DESC))[1]
    FROM g
    GROUP BY grp
    ORDER BY 1;
$$;

-- fn_interest_last_done(account, before): Ende der juengsten ERLEDIGTEN Zinsperiode (Scheduler-Zinsbuchung mit
--   interest_period_end oder interest_skips) -- mit p_before nur Perioden, die VOR diesem Tag enden; NULL = keine.
--   EINE Definition von "erledigt" fuer fn_interest_effective_period_start, fn_interest_due_open (offen nur danach) und
--   fn_interest_rate_preview (kein Wechsel vor bereits Verzinstem). Generische Zinsen (interest_period_end NULL) zaehlen nie.
--   plpgsql: transactions/interest_skips entstehen weiter unten in dieser Datei.
CREATE OR REPLACE FUNCTION finance.fn_interest_last_done(p_account_id int, p_before date DEFAULT NULL)
RETURNS date LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (SELECT max(d.pe) FROM (
        SELECT t.interest_period_end AS pe FROM finance.transactions t
         WHERE t.account_id = p_account_id AND t.category = 'interest' AND t.interest_period_end IS NOT NULL
           AND (p_before IS NULL OR t.interest_period_end < p_before)
        UNION ALL
        SELECT s.period_end FROM finance.interest_skips s
         WHERE s.account_id = p_account_id AND (p_before IS NULL OR s.period_end < p_before)) d);
END;
$$;

-- fn_interest_effective_period_start(account, period_end): der WIRKSAME Beginn der Zinsperiode, die an period_end endet
--   -- EINE Regel fuer fn_interest_due_open (Faelligkeit/Karte) und fn_interest_amount_due (Betrag):
--   1. Raster-Beginn im Regime des letzten Periodentags (fn_interest_period_start, geclamped auf dessen Anker).
--   2. Erste Periode eines Folge-Regimes (Raster-Beginn = Anker): ein Rhythmuswechsel loest KEINE eigene Gutschrift am
--      Wechseltag aus (Live-Befund 2026-10-24: 0,91-EUR-Karten fuer 23.10.-24.10. bei einer am Folgetag korrigierten
--      Kadenz; eine Bank zahlt dort nichts). Die Periode beginnt stattdessen am letzten Rasterpunkt eines frueheren
--      Regimes (Punkt <= dessen Ende, echte Gutschrift dort), sonst am Anker des ersten Regimes -- der Rest wird mit der
--      naechsten regulaeren Gutschrift im neuen Rhythmus verzinst (Satz-Mischung ueber beide: fn_interest_rate_segments).
--   3. Nie vor der juengsten erledigten (gebuchten/uebersprungenen) Periode vor period_end (Schutz vor Doppelverzinsung,
--      auch nach dem Kalender-Raster auf Bestandsdaten; im konsistenten Fall wirkungslos).
--   Init (nicht R__): die LANGUAGE-sql-fn fn_interest_due_open ruft sie und liegt alphabetisch davor. plpgsql, weil
--   transactions/interest_skips weiter unten in dieser Datei entstehen (sql wuerde den Body beim CREATE pruefen).
CREATE OR REPLACE FUNCTION finance.fn_interest_effective_period_start(p_account_id int, p_period_end date)
RETURNS date LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN (
    WITH regs AS (
        SELECT * FROM finance.fn_interest_regimes(p_account_id)
    ), cur AS (
        SELECT * FROM regs
         WHERE regime_start <= p_period_end - 1 AND (regime_end IS NULL OR p_period_end - 1 < regime_end)
         ORDER BY regime_start DESC LIMIT 1
    ), g AS (
        SELECT finance.fn_interest_period_start(cur.anchor, p_period_end, cur.n, cur.unit, cur.dom) AS ps,
               cur.anchor, cur.regime_start
          FROM cur
    ), prev AS (
        SELECT count(*) AS n_prev,
               min(r.anchor) AS first_anchor,
               max(x.pt) FILTER (WHERE x.pt > r.anchor) AS pt
          FROM regs r
          CROSS JOIN g
          CROSS JOIN LATERAL (SELECT finance.fn_interest_period_start(r.anchor, r.regime_end + 1, r.n, r.unit, r.dom) AS pt) x
         WHERE r.regime_start < g.regime_start
    )
    SELECT GREATEST(CASE WHEN g.ps = g.anchor AND prev.n_prev > 0 THEN COALESCE(prev.pt, prev.first_anchor) ELSE g.ps END,
                    finance.fn_interest_last_done(p_account_id, p_period_end))
      FROM g, prev);
END;
$$;

-- ============================================================
-- RECURRING PAYMENTS
-- Income and expenses with validity periods in one table.
-- For changed amounts (e.g. Elternzeit), add a new row with new valid_from.
-- Validity is HALF-OPEN [valid_from, valid_to): valid_to is the first day NO LONGER valid (stored exclusive;
-- the set/create fns convert the user's inclusive "last day" +1). Views, close_*, the split helper and
-- fn_recurring_due_open all read it this way. first_payment_date is only the rhythm anchor.
--
-- Example (Elternzeit):
--   name='Gehalt',    amount=3000,  valid_from=2024-01-01, valid_to=2024-12-01
--   name='Elterngeld',amount=1800,  valid_from=2024-12-01, valid_to=2025-06-01
--   name='Gehalt',    amount=3200,  valid_from=2025-06-01, valid_to=NULL
--
-- amount sign: positive = income, negative = expense
-- schedule_day_of_month: 1–28 specific day, -1 = last day, -2 = second-to-last day, NULL = relative to first_payment_date
-- monthly_equivalent: GENERATED — normalizes any payment schedule to a monthly amount for comparison
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.recurring_payments (
    id                    serial PRIMARY KEY,
    name                  varchar(100) NOT NULL,
    account_id            int NOT NULL REFERENCES finance.accounts(id),
    target_account_id     int,                             -- WS-2: gesetzt => interner Transfer (Ziel/Haben), account_id=Quelle/Soll; cashflow-neutral; FK+CHECK in der Migration unten (Singular-Name, wie asset_class)
    amount                numeric(12,2) NOT NULL,          -- signed: + income, - expense (Transfer: NEGATIV = Quell-Sicht; gebucht wird abs())
    schedule_interval     smallint NOT NULL DEFAULT 1,     -- every N units
    schedule_unit         finance.schedule_unit NOT NULL,
    schedule_day_of_month smallint,                        -- 1-28, -1 = last day, -2 = second-to-last day, NULL = relative
    schedule_days_of_month smallint[],                     -- feste Monatstage (>=2, z. B. Broker-Kalender {2,9,16,23}); nur unit=month, statt day_of_month
    first_payment_date    date NOT NULL,                   -- anchor for date calculation
    valid_from            date NOT NULL,
    valid_to              date,                            -- NULL = indefinite
    monthly_equivalent    numeric(12,2) GENERATED ALWAYS AS (
                              finance.fn_monthly_equivalent(amount, schedule_interval, schedule_unit,
                                                            coalesce(cardinality(schedule_days_of_month), 1))
                          ) STORED,                        -- read-only: amount normalized to monthly (zentrale fn)
    status                finance.payment_status NOT NULL DEFAULT 'active',
    notes                 text,
    created_at            timestamptz NOT NULL DEFAULT now()
);

-- Migration: monthly_equivalent auf die zentrale fn_monthly_equivalent umstellen (bestehende DBs).
-- Eine GENERATED-Expression ist nicht in-place aenderbar -> DROP+ADD der Spalte; abhaengige Views
-- (active_recurring_payments, monthly_cashflow_overview/_summary) werden per CASCADE mitgedroppt und
-- weiter unten via CREATE OR REPLACE VIEW neu erstellt. Idempotent (Guard auf die Expression).
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_attrdef d
        JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
        WHERE a.attrelid = 'finance.recurring_payments'::regclass
          AND a.attname = 'monthly_equivalent'
          -- voll-qualifiziert pruefen (B1): nach SET SCHEMA traegt die GENERATED-Expr noch die alte
          -- agent.fn_monthly_equivalent-Referenz -> ohne 'finance.'-Match wuerde sie nach dem Orphan-DROP
          -- ins Leere zeigen. So definiert der Bestands-Pfad die Spalte auf finance.fn_* um (fresh = no-op).
          AND pg_get_expr(d.adbin, d.adrelid) LIKE '%finance.fn_monthly_equivalent%'
    ) THEN
        ALTER TABLE finance.recurring_payments DROP COLUMN monthly_equivalent CASCADE;
        ALTER TABLE finance.recurring_payments ADD COLUMN monthly_equivalent NUMERIC(12,2)
            GENERATED ALWAYS AS (finance.fn_monthly_equivalent(amount, schedule_interval, schedule_unit)) STORED;
    END IF;
END $$;

-- Feste Monatstage (Live-Befund 2026-10-24: ein Broker fuehrt "woechentlich" an 2./9./16./23. aus = 4x/Monat, nicht
-- alle 7 Tage). schedule_days_of_month ersetzt bei unit=month den Einzeltag; CHECK = Gesetz (Tage nur bei month, nie
-- zusammen mit schedule_day_of_month, >= 2 -- ein Einzeltag gehoert in schedule_day_of_month: eine Schreibweise).
-- Additiv/nullable -> Init-only. monthly_equivalent zaehlt die Tage (4-arg fn_monthly_equivalent): Bestands-DBs
-- stellen die GENERATED-Expression per SET EXPRESSION (PG 17) um -- KEIN DROP+ADD CASCADE, das die abhaengigen
-- R__-Views auf Bestands-DBs verloere (der Treiber faehrt R__ nur bei geaenderter Pruefsumme neu). Guard auf die
-- neue Expression (der LIKE-Guard oben passt auch auf die alte Formel).
ALTER TABLE finance.recurring_payments ADD COLUMN IF NOT EXISTS schedule_days_of_month smallint[];
DO $$ BEGIN
    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_rp_schedule_days_chk;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_rp_schedule_days_chk CHECK (
        schedule_days_of_month IS NULL OR (
            schedule_unit = 'month' AND schedule_day_of_month IS NULL
            AND cardinality(schedule_days_of_month) >= 2
            AND finance.fn_valid_schedule_days(schedule_days_of_month)));
    IF NOT EXISTS (
        SELECT 1 FROM pg_attrdef d
        JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
        WHERE a.attrelid = 'finance.recurring_payments'::regclass
          AND a.attname = 'monthly_equivalent'
          AND pg_get_expr(d.adbin, d.adrelid) LIKE '%schedule_days_of_month%'
    ) THEN
        ALTER TABLE finance.recurring_payments ALTER COLUMN monthly_equivalent SET EXPRESSION AS (
            finance.fn_monthly_equivalent(amount, schedule_interval, schedule_unit,
                                          COALESCE(cardinality(schedule_days_of_month), 1)));
    END IF;
END $$;

-- Migration (WS-2 Multi-Member): target_account_id auf bestehenden DBs + FK + No-Self-Transfer-CHECK.
-- Additiv/nullable -> Init-only (Muster asset_class/person_id, KEINE V-Migration). target_account_id
-- IS NOT NULL markiert eine rp als INTERNEN Transfer (account_id=Quelle/Soll, target=Ziel/Haben) ->
-- recurring_cashflow_classified fuehrt sie als 'transfer' (cashflow-neutral, kein Doppelzaehlen) bzw. als
-- Sparziel-Rate in einen Topf als 'saving' (Audit Paket 3). Der
-- CHECK ist der Backstop gegen Selbst-Transfer (Quelle==Ziel); die fn liefert die freundliche {ok:false}.
-- DROP+ADD CONSTRAINT = idempotent je Apply; ADD COLUMN IF NOT EXISTS deckt Bestands-DBs.
ALTER TABLE finance.recurring_payments ADD COLUMN IF NOT EXISTS target_account_id int;
DO $$ BEGIN
    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_recurring_payments_target_account_fk;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_recurring_payments_target_account_fk
        FOREIGN KEY (target_account_id) REFERENCES finance.accounts(id);
    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_recurring_payments_no_self_transfer;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_recurring_payments_no_self_transfer
        CHECK (target_account_id IS NULL OR target_account_id <> account_id);
END $$;

-- Audit Paket 2 (A0): Vorgaenger-Kette (Lineage). Ein Validity-Split (fn_split_recurring_payment) oder ein
-- Reopen nach Soft-Close (fn_reopen_recurring_payment) legt eine Folge-rp an; predecessor_id zeigt auf die
-- Vorgaengerin. Besitzer-Entitaeten (Kredit/Sparplan/Sparziel/Versicherung/Vorsorge) zeigen immer auf den KOPF
-- der Kette (fn_repoint_recurring_owners); alte Vorkommen/Historie findet fn_recurring_lineage. DB-Gesetz:
-- lineare Kette (partieller UNIQUE = hoechstens ein Nachfolger) + FK NO ACTION (kein Mittelglied still
-- herausloeschbar; NO ACTION statt RESTRICT, damit eine ganze buchungsfreie Kette in EINEM Statement geloescht
-- werden kann). Additiv/nullable -> Init-only; der Bestands-Backfill ist einmalig -> V014.
ALTER TABLE finance.recurring_payments ADD COLUMN IF NOT EXISTS predecessor_id int;
DO $$ BEGIN
    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_recurring_payments_predecessor_fk;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_recurring_payments_predecessor_fk
        FOREIGN KEY (predecessor_id) REFERENCES finance.recurring_payments(id);
    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_recurring_payments_predecessor_not_self;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_recurring_payments_predecessor_not_self
        CHECK (predecessor_id IS NULL OR predecessor_id <> id);
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS finance_recurring_payments_predecessor_uq
    ON finance.recurring_payments (predecessor_id) WHERE predecessor_id IS NOT NULL;

-- fn_recurring_lineage: ids ALLER Glieder der Kette von p_rp_id (Vorgaenger UND Nachfolger, inkl. sich selbst).
-- EINE Adresse fuer "gehoert dieses Vorkommen zu einem Sparplan/Kredit/..." (Besitzer zeigen auf den Kopf),
-- Historie ueber alle Glieder und Doppel-Pruefung ueber die Kette. Init (nicht R__), weil Views
-- (R__finance_views.sql sortiert vor R__fn_*) sie lesen. Unbekannte id -> leere Menge.
CREATE OR REPLACE FUNCTION finance.fn_recurring_lineage(p_rp_id int)
RETURNS SETOF int LANGUAGE sql STABLE AS $$
    WITH RECURSIVE up AS (
        SELECT id, predecessor_id FROM finance.recurring_payments WHERE id = p_rp_id
        UNION ALL
        SELECT r.id, r.predecessor_id
        FROM finance.recurring_payments r JOIN up ON r.id = up.predecessor_id
    ), down AS (
        SELECT id FROM up WHERE predecessor_id IS NULL
        UNION ALL
        SELECT r.id
        FROM finance.recurring_payments r JOIN down ON r.predecessor_id = down.id
    )
    SELECT id FROM down;
$$;

-- fn_recurring_lineage_head: der KOPF (neuestes Glied, ohne Nachfolger) der Kette von p_rp_id — die rp, auf die
-- Besitzer-Entitaeten zeigen (Richtung alt -> neu). Unbekannte id -> NULL. Init aus demselben Grund wie oben.
CREATE OR REPLACE FUNCTION finance.fn_recurring_lineage_head(p_rp_id int)
RETURNS int LANGUAGE sql STABLE AS $$
    WITH RECURSIVE down AS (
        SELECT id FROM finance.recurring_payments WHERE id = p_rp_id
        UNION ALL
        SELECT r.id
        FROM finance.recurring_payments r JOIN down ON r.predecessor_id = down.id
    )
    SELECT d.id FROM down d
    WHERE NOT EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = d.id);
$$;

-- fn_recurring_current (WP2): das am Tag p_on GUELTIGE Glied der Kette ([valid_from, valid_to)), sonst der Kopf (Kette
-- beendet oder erst kuenftig gueltig). Die eine Adresse fuer "aktuelle Rate/aktueller Beitrag" einer Entitaet, deren
-- Rate nur noch an der Raten-Kette steht (loan_overview, active_insurances, pension_overview). Init wie oben.
CREATE OR REPLACE FUNCTION finance.fn_recurring_current(p_rp_id int, p_on date)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT r.id FROM finance.recurring_payments r
          WHERE r.id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
            AND r.valid_from <= p_on AND (r.valid_to IS NULL OR r.valid_to > p_on)
          ORDER BY r.valid_from DESC LIMIT 1),
        finance.fn_recurring_lineage_head(p_rp_id));
$$;

-- ============================================================
-- RECURRING PAYMENT SKIPS (Fälligkeits-Scheduler)
-- Schlankes State-Modell: "gebucht" wird aus finance_transactions abgeleitet
-- (Tx mit recurring_payment_id + recurring_due_date = due_date); nur "übersprungen"
-- ist nicht ableitbar -> hier materialisiert. Ein Skip je (Zahlung, Fälligkeit).
-- Ein Saldo-Abgleich materialisiert offene Vorkommen <= Stichtag-10 als Skip (fn_reconcile_account).
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.recurring_payment_skips (
    recurring_payment_id int NOT NULL REFERENCES finance.recurring_payments(id) ON DELETE CASCADE,
    due_date             date NOT NULL,
    skipped_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (recurring_payment_id, due_date)
);

-- ============================================================
-- RECURRING PAYMENT KEYS (Monats-Check WP-B)
-- Eindeutige Erkennungsmerkmale eines Dauerauftrags auf dem Kontoauszug, gelernt beim ersten bestaetigten Treffer
-- (source='statement') oder vom Nutzer genannt (source='user'). key_value ist normalisiert (Grossbuchstaben, ohne
-- Leerzeichen). Haengt an einem beliebigen Glied der Vorgaenger-Kette; Aufloesung ueber fn_recurring_lineage
-- (split-/reopen-fest, kein Repoint). Anbieterwechsel = neuer Schluessel, der alte bleibt Historie.
--   sepa_mandate      = '<Glaeubiger-ID>|<Mandatsreferenz>' -> identifiziert genau EINEN Vertrag -> global UNIQUE.
--   counterparty_iban = Gegen-IBAN -> NICHT global eindeutig (Gehalt + Bonus vom selben Arbeitgeber, Miete +
--                       Stellplatz beim selben Vermieter) -> je Dauerauftrag eindeutig; Matching filtert damit und
--                       entscheidet ueber die Betragsnaehe.
-- Interne Transfers lernen KEINE Schluessel: deren Gegen-IBAN ist accounts.account_number des Zielkontos.
-- ============================================================
DO $$ BEGIN
    CREATE TYPE finance.rp_key_type AS ENUM ('sepa_mandate', 'counterparty_iban');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS finance.recurring_payment_keys (
    id                   serial PRIMARY KEY,
    recurring_payment_id int NOT NULL REFERENCES finance.recurring_payments(id) ON DELETE CASCADE,
    key_type             finance.rp_key_type NOT NULL,
    key_value            text NOT NULL CHECK (key_value = upper(regexp_replace(key_value, '\s', '', 'g')) AND key_value <> ''),
    source               text NOT NULL DEFAULT 'statement' CHECK (source IN ('statement', 'user')),
    learned_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (recurring_payment_id, key_type, key_value)
);
CREATE UNIQUE INDEX IF NOT EXISTS finance_recurring_payment_keys_mandate_uq
    ON finance.recurring_payment_keys (key_value) WHERE key_type = 'sepa_mandate';
CREATE INDEX IF NOT EXISTS idx_recurring_payment_keys_value ON finance.recurring_payment_keys (key_type, key_value);

-- ============================================================
-- BANK STATEMENTS (Monats-Check WP-C)
-- EIN Aggregat je eingespieltem Kontoauszug — bewusst KEINE Umsatzzeilen (Owner-Vorgabe: Einzelumsaetze werden
-- nicht gespeichert; zugeordnete Zahlungen landen als Buchungen ihres Dauerauftrags, der Rest als EINE
-- Abgleichsbuchung). Zweck: Doppel-Einspiel-Sperre (UNIQUE je Konto + Zeitraum-Ende), Takt der Erinnerung,
-- Alltagsausgaben-Schaetzung der Deckungs-Vorschau (unmatched_out/in je Tag) und die Ruecknahme des LETZTEN Auszugs
-- (Provenienz: prev_last_reconciled_* = Abgleichsstand davor; Buchungen tragen transactions.bank_statement_id;
-- skipped = die beim Abgleich geschlossenen Vorkommen, learned_key_ids = die gelernten Schluessel). Fehlende Vorkommen
-- SIND Skips (recurring_payment_skips) — skipped haelt nur fest, welche dieser Lauf gesetzt hat.
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.bank_statements (
    id                           serial PRIMARY KEY,
    account_id                   int NOT NULL REFERENCES finance.accounts(id) ON DELETE CASCADE,
    period_start                 date NOT NULL,
    period_end                   date NOT NULL,
    opening_balance              numeric(12,2) NOT NULL,
    closing_balance              numeric(12,2) NOT NULL,
    currency                     char(3) NOT NULL,
    line_count                   int NOT NULL CHECK (line_count >= 0),
    matched_count                int NOT NULL CHECK (matched_count >= 0),
    unmatched_out                numeric(12,2) NOT NULL CHECK (unmatched_out <= 0),
    unmatched_in                 numeric(12,2) NOT NULL CHECK (unmatched_in >= 0),
    prev_last_reconciled_balance numeric(12,2),
    prev_last_reconciled_at      date,
    skipped                      jsonb NOT NULL DEFAULT '[]'::jsonb,
    learned_key_ids              int[] NOT NULL DEFAULT '{}',
    created_at                   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT finance_bank_statements_period_chk CHECK (period_start <= period_end),
    UNIQUE (account_id, period_end)
);

-- ============================================================
-- INTEREST SKIPS (WS-5c-B Zins-Faelligkeits-Scheduler)
-- Spiegel zu recurring_payment_skips, aber auf Konto-Ebene (Zinsgutschrift haengt am Konto,
-- nicht an einer recurring_payments-Zeile). "gebucht" wird aus finance.transactions abgeleitet
-- (category='interest' + account_id + interest_period_end=period_end); nur "uebersprungen" ist hier
-- materialisiert. Ein Skip je (Konto, period_end). period_end = stabiler Perioden-Identitaets-Key
-- (kongruent zu transactions.interest_period_end); seit Phase Z WS-Z6 traegt die Spalte ihren ehrlichen
-- Namen (vorher due_date, V009-Rename). recurring_payment_skips.due_date bleibt — dort ein echtes Datum.
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.interest_skips (
    account_id  int NOT NULL REFERENCES finance.accounts(id) ON DELETE CASCADE,
    period_end  date NOT NULL,
    skipped_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, period_end)
);

-- ============================================================
-- REAL ESTATE
-- Assets (not accounts) — no transaction flow recorded here.
-- Loans (mortgages) reference this table via real_estate_id.
-- current_value is updated manually or periodically by the agent.
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.real_estate (
    id               serial PRIMARY KEY,
    name             varchar(100) NOT NULL,             -- e.g. 'Wohnung München'
    current_value    numeric(12,2),                     -- estimated current market value
    value_updated_at date,                              -- date of last valuation
    owner_person_id  text,                              -- Multi-Member: Eigentümer-Person, das EINZIGE Inhaber-Feld (Slug aus family; NULL=Haushalt); FK unten. WS-4: Freitext-owner abgelöst.
    status           finance.property_status NOT NULL DEFAULT 'active',
    notes            text,
    sale_tx_id       int,                               -- Audit F5: Erloes-Tx von fn_sell_real_estate; Void dieser Tx setzt status zurueck. FK -> transactions UNTEN (Tabelle entsteht spaeter).
    created_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE finance.real_estate ADD COLUMN IF NOT EXISTS sale_tx_id int;

-- ============================================================
-- PENSION / ALTERSVORSORGE
-- Retirement provisions as net-worth assets (German 3-pillar model). Asset-style like real_estate:
-- current_value = accumulated value (Rückkaufswert/Deckungskapital), updated manually/periodically.
-- For statutory (gesetzliche Rente) current_value is often unknown -> NULL allowed.
-- An optional monthly contribution (Beitrag) is mirrored as a finance_recurring_payments row
-- (recurring_payment_id), analogous to insurances, so it shows up in the cashflow.
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.pension (
    id                        serial PRIMARY KEY,
    name                      varchar(100) NOT NULL,        -- e.g. 'Allianz Rürup', 'DRV gesetzlich'
    pension_type              finance.pension_type NOT NULL,
    provider                  varchar(100),                 -- Anbieter/Versorgungsträger
    contract_number           varchar(50),
    owner_person_id           text,                         -- Multi-Member: Eigentümer-Person, das EINZIGE Inhaber-Feld (Slug aus family; NULL=Haushalt); FK unten. WS-4: Freitext-owner abgelöst.
    current_value             numeric(12,2),                -- Rückkaufswert/Deckungskapital; NULL if unknown
    value_updated_at          date,                         -- date of last valuation
    guaranteed_monthly_pension numeric(12,2),               -- optional: guaranteed monthly payout at retirement
    retirement_start_date     date,                         -- optional: expected start of payout
    recurring_payment_id      int REFERENCES finance.recurring_payments(id), -- optional monthly Beitrag
    status                    finance.pension_status NOT NULL DEFAULT 'active',
    notes                     text,
    created_at                timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- PENSION STATEMENTS (Standmitteilungen) — datierte Snapshots als CHILD der EINEN Pension-Zeile.
-- Renteninformation (DRV), bAV-/Riester-/Rürup-Standmitteilungen, korean. NPS-Bescheid: jaehrliche
-- BEOBACHTUNGEN desselben Anspruchs, KEINE neuen Anwartschaften — deshalb nie eigene
-- finance_pension-Rows (wuerden Net-Worth doppelt zaehlen, fn_resolve_pension brechen,
-- finance_pension_rp_uq kollidieren). Zeitreihe, nie ueberschreiben; der Advisor rechnet stets
-- mit dem JUENGSTEN Statement (max statement_date — kein dupliziertes "current"-Feld am Parent).
-- em_monthly = Rente bei voller Erwerbsminderung (Zahl AUF dem gRV-Statement, kein Pension-Typ;
-- kritischster Input: DIN-Stufe-1-Arbeitskraftluecke = Bedarf - EM-Rente).
-- disposable Child => ON DELETE CASCADE (ON-DELETE-Politik .claude/rules/sql.md *Integritaets-Konventionen*).
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.pension_statements (
    id             serial PRIMARY KEY,
    pension_id     int NOT NULL REFERENCES finance.pension(id) ON DELETE CASCADE,
    statement_date date NOT NULL,                 -- Datum der Standmitteilung (Pflicht-Metadatum)
    reached_claim  numeric(12,2),                 -- erreichter monatlicher Anspruch (ohne weitere Beitraege)
    projection     numeric(12,2),                 -- Hochrechnung monatlich (Annahme: Beitraege wie bisher)
    em_monthly     numeric(12,2),                 -- Rente bei voller Erwerbsminderung (monatlich)
    is_nominal     boolean NOT NULL DEFAULT TRUE, -- Nominal-Caveat: Werte ohne Inflationsanpassung
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (pension_id, statement_date)           -- dieselbe Standmitteilung nie doppelt
);

CREATE INDEX IF NOT EXISTS finance_pension_statements_pension_idx
    ON finance.pension_statements (pension_id, statement_date DESC);

-- ============================================================
-- LOANS
-- Full amortization data for interest/repayment calculation.
--
-- Each loan requires a dedicated account (account_type='loan') in finance_accounts.
-- That account's balance = current Restschuld (negative), auto-maintained by trigger.
--
-- Setup:
--   1. CREATE finance_accounts (account_type='loan') → note its id as loan_account_id
--   2. CREATE finance_loans linking loan_account_id + debit_account_id (Girokonto)
--   3. Book disbursement as two transactions:
--        Girokonto:    amount = +original_amount,  category='disbursement', loan_id=X
--        Kreditkonto:  amount = -original_amount,  category='disbursement', loan_id=X
--
-- Monthly payment (Annuität = Zins + Tilgung) — two transactions per installment:
--        Girokonto:    amount = -rate,              category='loan_payment'
--        Kreditkonto:  amount = +principal_portion, category='principal'
--   Interest portion is implicit: rate - principal_portion.
--
-- Zins/Tilgung einer Rate rechnet die DB immer aus der AKTUELLEN Restschuld (fn_loan_monthly_interest;
-- loan_overview.monthly_*_current, fn_get_loan_payment_split) -- nie aus Ursprungswerten (Live-Befund 2026-10-24:
-- die "anfaengliche Tilgung" eines alten Angebots passt bei einem laufenden Kredit nicht zur Rate; die Rate ist die
-- Wahrheit). Die frueheren GENERATED-Spalten annuity_rate / origination_monthly_* entfielen (finance:V025).
--
-- EINE QUELLE (WP2 "Finanzen schlank", finance:V026): Rate, Rhythmus und Abbuchungstag stehen NUR an der Raten-Kette
-- (recurring_payment_id -> Kopf, fn_recurring_lineage); loan_overview liest das heute gueltige Glied
-- (fn_recurring_current). Eine Ratenaenderung legt ein neues Glied an (Historie). Die frueheren Kopien
-- monthly_annuity / schedule_interval / schedule_unit / schedule_day_of_month und die gespeicherte "anfaengliche
-- Tilgung" principal_rate entfielen; loan_overview.initial_principal_rate rechnet sie aus Kreditbetrag + erster Rate.
--   Laufender Kredit (Kreditkonto mit opening_balance_date, ohne Auszahlungskonto): Pflicht nur Restschuld, Zins,
--   Abbuchungskonto (+ Rate mit naechster Faelligkeit); original_amount / disbursement_date sind nachtragbar.
--   term_end_date = Laufzeitende (letzte Rate; bei Schlussrate deren Termin, Betrag in notes).
--
-- Refinancing / Umschuldung:
--   - Set old loan: status='refinanced'
--   - Settle old loan account: amount = +Restschuld, category='settlement'
--   - Create new finance_accounts (new Kreditkonto) + new finance_loans entry
--   - Link successive loans via real_estate_id or name convention
--
-- Family debts / paused repayment: keine Raten-Kette (recurring_payment_id NULL), status='paused'
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.loans (
    id                        serial PRIMARY KEY,
    name                      varchar(100) NOT NULL,
    lender                    varchar(100),              -- bank, family member, etc.
    borrower_person_id        text,                      -- Multi-Member: Kreditnehmer-Person, das EINZIGE Inhaber-Feld (Slug aus family; NULL=Haushalt); FK unten. WS-4: Freitext-borrower abgelöst.
    original_amount           numeric(12,2),             -- original loan sum; informational for a running loan (NULL = not given)
    disbursement_date         date,                      -- payout date; informational for a running loan (NULL = not given)
    interest_rate             numeric(6,4) NOT NULL,     -- annual rate, e.g. 3.5000 = 3.5%
    interest_rate_fixed_until date,                      -- Zinsbindungsende
    term_end_date             date,                      -- Laufzeitende (Termin der letzten Rate); NULL = nicht angegeben
    -- GERUEST (WP2): finance:V012/V024 setzen ungeguardet einen CHECK auf diese Spalte -> auf einer FRISCHEN DB muss
    -- sie bis dahin existieren; finance:V026 droppt sie danach (Abbuchungstag steht nur an der Raten-Kette).
    schedule_day_of_month     smallint,
    status                    finance.loan_status NOT NULL DEFAULT 'active',
    loan_account_id           int NOT NULL REFERENCES finance.accounts(id), -- Kreditkonto (negative balance = Restschuld)
    debit_account_id          int REFERENCES finance.accounts(id),          -- Abbuchungskonto fuer die Rate (Girokonto)
    disbursement_account_id   int REFERENCES finance.accounts(id),          -- Konto, auf das die Kreditsumme floss; NULL = an Dritte/Verkaeufer oder laufender Kredit (keine Auszahlungsbuchung)
    real_estate_id            int REFERENCES finance.real_estate(id),
    recurring_payment_id      int REFERENCES finance.recurring_payments(id),
    notes                     text,
    settled_from              jsonb,                     -- Audit F5: Zustand VOR fn_settle_loan {status, rp_status, rp_valid_to}; fn_void_transaction stellt ihn exakt wieder her
    created_at                timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE finance.loans ADD COLUMN IF NOT EXISTS settled_from jsonb;
-- Laufender Kredit: Ursprungswerte optional (Live-Befund 2026-10-24); idempotent.
ALTER TABLE finance.loans ALTER COLUMN original_amount DROP NOT NULL;
ALTER TABLE finance.loans ALTER COLUMN disbursement_date DROP NOT NULL;

-- Hinweis: der Rename payout_account_id -> disbursement_account_id (5d) lebt als versionierte
-- Migration packages/finance/db/migrations/V001__rename_loan_payout_to_disbursement.sql (laeuft NACH den Inits,
-- VOR den R__-View-Repeatables). CREATE TABLE oben traegt den Endzustand disbursement_account_id.

ALTER TABLE finance.loans ADD COLUMN IF NOT EXISTS term_end_date date;

-- Constraint: ein aktiver Kredit hat eine Raten-Kette; paused/paid_off/refinanced duerfen ohne sein.
-- WP2: Bestands-DBs tauschen den alten CHECK (monthly_annuity) in finance:V026 NACH dessen Pre-flight -> hier erst,
-- wenn die Kopie monthly_annuity weg ist (frische DB sofort; Init laeuft vor den V-Migrationen).
-- Laufzeit-CHECKs (Spiegel der fn_create_loan/fn_set_loan-Guards): Zinsbindung nicht nach dem Laufzeitende, Laufzeitende
-- nicht vor der Auszahlung.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'finance' AND table_name = 'loans' AND column_name = 'monthly_annuity') THEN
        ALTER TABLE finance.loans DROP CONSTRAINT IF EXISTS finance_loans_active_needs_annuity;
        ALTER TABLE finance.loans ADD CONSTRAINT finance_loans_active_needs_annuity
            CHECK (recurring_payment_id IS NOT NULL OR status <> 'active');
    END IF;
    ALTER TABLE finance.loans DROP CONSTRAINT IF EXISTS finance_loans_term_end_chk;
    ALTER TABLE finance.loans ADD CONSTRAINT finance_loans_term_end_chk CHECK (
        term_end_date IS NULL
        OR ((interest_rate_fixed_until IS NULL OR interest_rate_fixed_until <= term_end_date)
            AND (disbursement_date IS NULL OR term_end_date >= disbursement_date)));
END $$;

-- ============================================================
-- INSURANCES
-- EINE QUELLE (WP2 "Finanzen schlank", finance:V027): Beitrag je Abbuchung, Rhythmus, Abbuchungstag, Vertragsende
-- und Abbuchungskonto stehen NUR an der Raten-Kette (recurring_payment_id -> Kopf); active_insurances liest das heute
-- gueltige Glied und leitet Jahres-/Monatswert ab (fn_annual_equivalent, rp.monthly_equivalent). Die frueheren Kopien
-- annual_premium / monthly_equivalent / schedule_* / valid_to / account_id entfielen. fn_create_insurance verlangt einen
-- Beitrag; ohne Raten-Kette gibt es nur Altbestand/Direkt-Anlagen. valid_from = Vertragsbeginn (eigener Fakt: rp.valid_from klemmt auf den
-- Konto-Stichtag); status = Vertragszustand (cancelled/expired sind kein Zahlungszustand).
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.insurances (
    id                    serial PRIMARY KEY,
    name                  varchar(100) NOT NULL,
    insurance_company     varchar(100),
    policy_number         varchar(50),
    policyholder_person_id text,                         -- Multi-Member: Versicherungsnehmer-Person, das EINZIGE Inhaber-Feld (Slug aus family; NULL=Haushalt); FK unten. WS-4: Freitext-policyholder abgelöst.
    -- GERUEST (WP2): finance:V012/V024 setzen ungeguardet einen CHECK auf diese Spalte -> auf einer FRISCHEN DB muss
    -- sie bis dahin existieren; finance:V027 droppt sie danach (Abbuchungstag steht nur an der Raten-Kette).
    schedule_day_of_month smallint,
    valid_from            date NOT NULL,                 -- Vertragsbeginn
    status                finance.insurance_status NOT NULL DEFAULT 'active',
    recurring_payment_id  int REFERENCES finance.recurring_payments(id),   -- Kopf der Beitrags-Kette (NULL nur Altbestand)
    -- WS-0b (estate): Nachlass-relevante Policen-Attribute (additiv nullable, Init-only, KEIN V).
    -- insurance_type = grobe Policen-Klasse (geschlossene Liste, s. CHECK; life/accident tragen Todesfall-
    --   Meldefristen); beneficiary = benannter Bezugsberechtigter (schlaegt das Testament, Bezugsrecht-Falle);
    -- coverage_amount = Versicherungssumme in EUR; claim_deadline_hours = die AVB-Meldefrist JE POLICE
    --   (z. B. 48h Unfalltod GDV-AUB, 24-72h Lebensversicherung). estate liest sie ueber
    --   finance.fn_insurance_register() fuer Gap-Analyse + Todesfall-Checkliste; finance besitzt die Spalten.
    insurance_type        text,
    beneficiary           text,
    coverage_amount       numeric(14,2),
    claim_deadline_hours  int,
    notes                 text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    -- WS-0b: geschlossene insurance_type-Liste + Wert-Grenzen = strukturelle Backstops (Description fuehrt den Agenten).
    CONSTRAINT finance_insurances_type_chk CHECK (
        insurance_type IS NULL OR insurance_type IN (
            'life', 'accident', 'disability', 'health', 'care',
            'liability', 'household', 'residential_building', 'legal', 'vehicle', 'other'
        )
    ),
    CONSTRAINT finance_insurances_coverage_amount_chk CHECK (coverage_amount IS NULL OR coverage_amount >= 0),
    CONSTRAINT finance_insurances_claim_deadline_hours_chk CHECK (claim_deadline_hours IS NULL OR claim_deadline_hours > 0)
);

-- Migration (WS-0b estate): die vier Nachlass-Felder additiv/idempotent auf Bestands-DBs (Init-only, KEIN V
-- — rein additiv nullable). Die CHECKs (geschlossene insurance_type-Liste + Wert-Grenzen) sind der Backstop.
ALTER TABLE finance.insurances ADD COLUMN IF NOT EXISTS insurance_type text;
ALTER TABLE finance.insurances ADD COLUMN IF NOT EXISTS beneficiary text;
ALTER TABLE finance.insurances ADD COLUMN IF NOT EXISTS coverage_amount numeric(14,2);
ALTER TABLE finance.insurances ADD COLUMN IF NOT EXISTS claim_deadline_hours int;
DO $$ BEGIN
    ALTER TABLE finance.insurances DROP CONSTRAINT IF EXISTS finance_insurances_type_chk;
    ALTER TABLE finance.insurances ADD CONSTRAINT finance_insurances_type_chk
        CHECK (insurance_type IS NULL OR insurance_type IN (
            'life', 'accident', 'disability', 'health', 'care',
            'liability', 'household', 'residential_building', 'legal', 'vehicle', 'other'));
    ALTER TABLE finance.insurances DROP CONSTRAINT IF EXISTS finance_insurances_coverage_amount_chk;
    ALTER TABLE finance.insurances ADD CONSTRAINT finance_insurances_coverage_amount_chk
        CHECK (coverage_amount IS NULL OR coverage_amount >= 0);
    ALTER TABLE finance.insurances DROP CONSTRAINT IF EXISTS finance_insurances_claim_deadline_hours_chk;
    ALTER TABLE finance.insurances ADD CONSTRAINT finance_insurances_claim_deadline_hours_chk
        CHECK (claim_deadline_hours IS NULL OR claim_deadline_hours > 0);
END $$;

-- ============================================================
-- DEPOT HOLDINGS (stocks, ETFs, crypto)
-- Stores ISIN/symbol and share count only.
-- Market value = shares × live price (fetched by agent from external API, NOT stored here).
-- 8 decimal places on shares to support crypto fractions.
-- Buy/sell cash transactions are booked on the settlement account (not the depot account);
-- holding_id on each transaction links back to the affected position here.
-- shares is maintained automatically by trigger trg_finance_update_holding_shares
-- (source of truth = SUM(finance_transactions.shares WHERE holding_id = X)) —
-- the agent never writes this column directly.
-- After full sell-off, shares=0; the row stays for history (filter via WHERE shares > 0).
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.depot_holdings (
    id                     serial PRIMARY KEY,
    account_id             int NOT NULL REFERENCES finance.accounts(id),
    isin                   varchar(12),                 -- NULL for crypto (no ISIN)
    symbol                 varchar(20) NOT NULL,        -- ticker (e.g. VWCE) or crypto symbol (e.g. BTC)
    name                   varchar(100) NOT NULL,
    shares                 numeric(18,8) NOT NULL DEFAULT 0,  -- trigger-maintained; never write directly
    average_purchase_price numeric(20,8),               -- gleitender Durchschnitt (fn_holding_avg_cost) inkl. Gebuehren; trigger-maintained; never write directly. (20,8) wie market_prices.price (Audit Paket 2: Mini-Kurse < 0.0001; Bestand via V013)
    currency               char(3) NOT NULL DEFAULT 'EUR',
    asset_class            varchar(40),                 -- WS2b: Allokations-Block-KEY (lowercase snake, KEIN FK -> advisor-JSON-key); CHECK = Backstop; auto-getaggt beim Kauf (HITL), korrigierbar via set_holding
    provider_symbol        varchar(30),                 -- Phase M / WP-4: optionaler Yahoo-Finance-Feed-Symbol-Override (EINHEITLICH Yahoo). Aktie/ETF: Ticker mit Boersen-Suffix (VWCE.DE Xetra / AAPL US / VWRL.L London). Krypto: Yahoos TICKER-FIAT (BTC-EUR; bei mehrdeutigem Ticker das eindeutige UNI7083-USD). NULL = nicht abweichend -> Cron nutzt symbol (Aktie) bzw. symbol||'-EUR' (Krypto). Frei (kein FK/CHECK), HITL-gesetzt via book_stock_buy/set_holding.
    quote_currency         char(3),                     -- Phase M: erwartete native Quote-Waehrung des Kurs-Feeds (z. B. USD bei US-Listing trotz EUR-gefuehrter Position). NULL = nicht abweichend -> Holding-Waehrung. FK->currencies (Backstop, unten); fn_upsert_market_prices nimmt COALESCE(quote_currency, currency).
    updated_at             timestamptz NOT NULL DEFAULT now()
);

-- Migration: set DEFAULT 0 on existing installs where shares had no default
ALTER TABLE finance.depot_holdings ALTER COLUMN shares SET DEFAULT 0;

-- Migration (WS2b): asset_class-Tag auf bestehenden DBs + Format-CHECK (Singular, Freitext, KEIN FK —
-- referenziert einen user-definierten target_allocation.blocks[].key im Plan-Sidecar; das Format-CHECK
-- ist der strukturelle Backstop, die Drift-fn meldet unmapped/null_tag als pflichtigen Orphan-Report).
ALTER TABLE finance.depot_holdings ADD COLUMN IF NOT EXISTS asset_class varchar(40);
DO $$ BEGIN
    ALTER TABLE finance.depot_holdings DROP CONSTRAINT IF EXISTS finance_depot_holdings_asset_class_fmt;
    ALTER TABLE finance.depot_holdings ADD CONSTRAINT finance_depot_holdings_asset_class_fmt
        CHECK (asset_class IS NULL OR asset_class ~ '^[a-z0-9_]+$');
END $$;

-- Migration (Phase M): provider_symbol + quote_currency auf bestehenden DBs. Additiv/nullable -> Init-only
-- (Muster asset_class/person_id, KEINE V-Migration). provider_symbol = freier Feed-Symbol-Override (kein
-- FK/CHECK). quote_currency = native Quote-Waehrung mit FK->currencies als Backstop (der primaere Pfad ist
-- fn_book_stock_buy/fn_set_holding via fn_ensure_currency -> {ok:false} bei ungueltigem Code; der FK greift
-- nur bei Umgehung). NULL bei beiden = "nicht abweichend" (Cron nutzt symbol bzw. Holding-Waehrung).
ALTER TABLE finance.depot_holdings ADD COLUMN IF NOT EXISTS provider_symbol varchar(30);
ALTER TABLE finance.depot_holdings ADD COLUMN IF NOT EXISTS quote_currency  char(3);
DO $$ BEGIN
    ALTER TABLE finance.depot_holdings DROP CONSTRAINT IF EXISTS finance_depot_holdings_quote_currency_fk;
    ALTER TABLE finance.depot_holdings ADD CONSTRAINT finance_depot_holdings_quote_currency_fk
        FOREIGN KEY (quote_currency) REFERENCES finance.currencies(code);
END $$;

-- Partial UNIQUE indexes: one holding per (depot, isin) for stocks/ETFs;
-- one holding per (depot, symbol) for crypto (isin IS NULL).
CREATE UNIQUE INDEX IF NOT EXISTS finance_depot_holdings_isin_uq
    ON finance.depot_holdings (account_id, isin)
    WHERE isin IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS finance_depot_holdings_symbol_uq
    ON finance.depot_holdings (account_id, symbol)
    WHERE isin IS NULL;

-- ============================================================
-- SAVINGS GOALS
-- Covers savings targets. The agent calculates the required monthly savings rate
-- and creates a recurring_payment for it; recurring_payment_id links back to it.
-- Progress = RESERVE STAND (Phase S, Ziel-Tag-Envelope + Reserve-Journal): finance.savings_goal_progress.
-- current_amount = Cash-Anteil (signed SUM(transactions.amount WHERE savings_goal_id), ueber beliebig viele
-- Konten, je via fn_to_eur konvertiert) + Depot-Anteil (signed SUM(fn_to_eur(delta_native, currency, value_date))
-- je Ziel — ein append-only Reserve-Journal, WS-B/WP-3b). NICHT der Raten-Zaehler. Der MARKTWERT eines Depots ist Deckel/Deckung (depot_
-- reserve_status), NIE die gespeicherte Reserve (Kurs-Explosion blaeht den Fortschritt nicht auf).
-- WS-B (2026-06-25): die fruehen savings_goal_holdings (ganzer-Bestand-Marktwert, doppelzaehl-anfaellig) +
-- savings_goal_allocations (Earmark/FIRE) sind RETIRED (finance:V008 DROP) -> Details docs/reference/finance.md "Sparziel-Reserve".
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.savings_goals (
    id                   serial PRIMARY KEY,
    name                 varchar(100) NOT NULL,         -- e.g. 'Korea Flug', 'Notgroschen'
    goal_type            varchar(50),                   -- optional free text label
    target_amount        numeric(12,2) NOT NULL,
    target_date          date NOT NULL,
    beneficiary_person_id text,                          -- Multi-Member: begünstigte Person (Slug aus family; NULL=Haushalt); FK unten
    recurring_payment_id int REFERENCES finance.recurring_payments(id), -- monthly savings rate created by agent
    status               finance.goal_status NOT NULL DEFAULT 'active',
    priority             smallint,                       -- WS-C1: Engpass-Reihung (kleiner = wichtiger; NULL = unpriorisiert)
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- WS-C1 (Phase S): priority — additiv/nullable -> Init-only (Muster asset_class/savings_goal_id/owner_person_id,
-- KEINE V-Migration). Engpass-Reihung der Ziele: target_date ASC, priority ASC NULLS LAST (kleiner = wichtiger,
-- NULL = unpriorisiert ans Ende). Reine Anzeige-/Reasoning-Hilfe (kein Constraint) -> der Advisor reasoned
-- darueber, die DB rechnet nichts daraus ab. ADD COLUMN deckt Bestands-DBs; die CREATE TABLE oben deckt frische.
ALTER TABLE finance.savings_goals ADD COLUMN IF NOT EXISTS priority smallint;

-- ============================================================
-- SAVINGS GOAL RESERVE ENTRIES (WS-B Phase S — Depot-Anteil einer Reserve als APPEND-ONLY Journal)
-- Der Depot-Anteil einer Sparziel-Reserve = SUM(fn_to_eur(delta_native, currency, value_date)) je Ziel (WP-3b).
-- Jede Reserve-Bewegung haengt EINE Zeile
-- an (NIE UPDATE/DELETE einer Zahl, ausser CASCADE bei Ziel-Hard-Delete) -> der Stand ist DERIVED -> kann
-- strukturell nicht driften (loest den Ledger-Korruptions-Vektor des gespeicherten-gebumpten Betrags).
--   * delta_native + currency (WP-3b): vorzeichenbehaftete Bewegung in der NATIVE-Waehrung `currency` (NICHT der
--     Stand, NICHT zwingend EUR). sparplan_buy speichert die Depot-Waehrung (fn_book_stock_buy, symmetrisch zum
--     nativen Cash-Bein -> Konservierung); manual speichert EUR (fn_book_savings_reservation, Owner nennt ein
--     absolutes EUR-Ziel). Die EUR-Umrechnung macht erst die VIEW via fn_to_eur(delta_native, currency, value_date)
--     -> kein fn_to_eur am Insert (waere NULL bei fehlendem Kurs -> NOT-NULL-CHECK-Crash) und beide Reserve-Legs
--     (Cash+Depot) tragen dieselbe Live-Konvertierungs-Semantik (kein Frozen-vs-Live-Drift). CHECK (delta_native<>0):
--     eine No-op-Zeile ist sinnlos -> die fn lehnt delta=0 vorher ab; der CHECK ist der strukturelle Backstop.
--   * value_date: das FX-Umrechnungsdatum der Zeile = transaction_date des Kaufs (sparplan_buy) bzw. CURRENT_DATE
--     (manual). Pinnt den Kurs deterministisch -> die Depot-Reserve driftet nicht bei spaeteren Kurs-Revisionen und
--     bleibt zum getaggten Cash-Bein (das am transaction_date konvertiert) exakt gegengleich.
--   * kind: 'sparplan_buy' (Stage 2: goal-verknuepfter Kauf, source_tx_id gesetzt), 'manual' (Hand-Zuordnung
--     via fn_book_savings_reservation), 'derisk' (Absichern/Verkauf -> Reserve senken). CHECK = Backstop.
--   * source_tx_id: Herkunfts-Buchung (Stage 2 Sparplan-Kauf); NULL bei manueller Zuordnung. ON DELETE SET
--     NULL — eine spaeter stornierte Kauf-Tx soll das Journal nicht blocken (Provenance-Link entfaellt, Zahl bleibt).
--   * account_id: das Depot-Konto, gegen dessen Gesamt-Marktwert die Reserve gedeckt wird (depot_reserve_status).
--   * Multi-Row-Invariante "SUM(delta) >= 0 je Ziel" ist NICHT per Gate-Trigger erzwungen (MVCC-Race) -> der
--     book-fn-Guard ({ok:false} wenn der Append die Summe negativ machen wuerde) + der Waechter-Advisory tragen sie.
-- ON DELETE CASCADE (savings_goal_id): die Zuordnung ist Metadaten ohne Eigenwert -> faellt mit dem Ziel weg
--   (abgebrochen/Hard-Delete); der Bestand selbst (depot_holdings) bleibt IMMER (RESTRICT, nie hier beruehrt).
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.savings_goal_reserve_entries (
    id              serial PRIMARY KEY,
    savings_goal_id int           NOT NULL REFERENCES finance.savings_goals(id) ON DELETE CASCADE,
    account_id      int           NOT NULL REFERENCES finance.accounts(id),       -- Depot-Konto (Marktwert-Deckung)
    delta_native    numeric(14,2) NOT NULL CHECK (delta_native <> 0),             -- vorzeichenbehaftete Bewegung in der `currency`-Waehrung (WP-3b)
    currency        char(3)       NOT NULL DEFAULT 'EUR' REFERENCES finance.currencies(code),  -- Waehrung von delta_native (Depot-Waehrung bei sparplan_buy, EUR bei manual)
    value_date      date          NOT NULL DEFAULT current_date,                  -- FX-Umrechnungsdatum (= Kauf-transaction_date bzw. CURRENT_DATE)
    source_tx_id    int,          -- Stage 2: Kauf-Tx; NULL bei manual. FK -> finance.transactions UNTEN (die Tabelle entsteht erst spaeter in dieser Datei -> Constraint nachgezogen).
    kind            text          NOT NULL CHECK (kind IN ('sparplan_buy', 'manual', 'derisk', 'void')),
    created_at      timestamptz   NOT NULL DEFAULT now()
);
-- Audit F4: 'void' = Gegenzeile, die fn_void_transaction anhaengt, wenn eine Kauf-Tx mit Journal-Zeile
-- (source_tx_id) storniert wird (delta = -original, gleiche currency/value_date -> exakt gegengleich).
-- Append-only bleibt gewahrt: die Ursprungszeile wird nie geloescht/geaendert. DROP+ADD = Bestands-DBs.
DO $$ BEGIN
    ALTER TABLE finance.savings_goal_reserve_entries DROP CONSTRAINT IF EXISTS savings_goal_reserve_entries_kind_check;
    ALTER TABLE finance.savings_goal_reserve_entries ADD CONSTRAINT savings_goal_reserve_entries_kind_check
        CHECK (kind IN ('sparplan_buy', 'manual', 'derisk', 'void'));
END $$;

CREATE INDEX IF NOT EXISTS finance_savings_goal_reserve_entries_goal_idx
    ON finance.savings_goal_reserve_entries (savings_goal_id);
CREATE INDEX IF NOT EXISTS finance_savings_goal_reserve_entries_account_idx
    ON finance.savings_goal_reserve_entries (account_id);

-- ============================================================
-- SAVINGS PLANS (Sparpläne)
-- Recurring automated investment plans (stocks/ETF/crypto).
-- Each plan owns one recurring_payment (settlement-account cash debit, monthly equivalent
-- visible in cashflow) + references the target depot + security metadata.
-- Execution = fn_book_stock_buy called with recurring_payment_id stamped ->
--   buy-Tx marks the occurrence as "booked" in fn_recurring_due_open automatically.
-- Smart-Close: no transactions -> hard-DELETE; transactions exist -> soft-close (valid_to + paused).
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.savings_plans (
    id                   serial PRIMARY KEY,
    name                 varchar(100) NOT NULL,
    depot_id             int NOT NULL REFERENCES finance.accounts(id) ON DELETE RESTRICT,
    isin                 varchar(12),                     -- NULL for crypto depots
    symbol               varchar(20) NOT NULL,            -- ticker (e.g. VWCE) or crypto (e.g. BTC)
    security_name        varchar(100) NOT NULL,
    recurring_payment_id int NOT NULL REFERENCES finance.recurring_payments(id) ON DELETE RESTRICT,
    beneficiary_person_id text,                           -- Multi-Member: begünstigte Person (Slug aus family; NULL=Haushalt); FK unten
    asset_class          varchar(40),                     -- Phase L WS-6: Allokations-Block-KEY (lowercase snake, CHECK = Backstop, KEIN FK; Muster depot_holdings.asset_class). Bei Plan-Anlage erfasst, an jede Ausfuehrung vererbt -> Sparplaene erzeugen nie leere Tags
    status               finance.payment_status NOT NULL DEFAULT 'active',
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- Case-insensitive unique name for resolver
CREATE UNIQUE INDEX IF NOT EXISTS finance_savings_plans_name_uq
    ON finance.savings_plans (lower(name));

-- WS-B Stufe 2 (Phase S): savings_goal_id — ein Sparplan gehoert zu EINEM Sparziel (Quellen-Verknuepfung).
-- Ein goal-verknuepfter Sparplan-Kauf speist den Depot-Anteil der Ziel-Reserve (Zwei-Schritt-Auto-Journal in
-- fn_book_stock_buy: Cash-Soll-Bein getaggt + savings_goal_reserve_entries-Zeile kind='sparplan_buy'). Additiv/
-- nullable (NULL = freistehender Sparplan, kein Ziel) -> Init-only (Muster asset_class/savings_goal_id/person_id,
-- KEINE V-Migration). **ON DELETE SET NULL ist Pflicht**: sonst blockt ein verknuepfter Sparplan den Ziel-Hard-
-- Delete (fn_close_savings_goal DELETE savings_goals bei tx_count=0) -> ein geloeschtes Ziel laesst den Sparplan
-- entkoppelt stehen (der Plan selbst bleibt IMMER). DROP+ADD CONSTRAINT idempotent; ADD COLUMN IF NOT EXISTS
-- deckt Bestands-DBs, die CREATE TABLE oben deckt frische.
ALTER TABLE finance.savings_plans ADD COLUMN IF NOT EXISTS savings_goal_id int;
DO $$ BEGIN
    ALTER TABLE finance.savings_plans DROP CONSTRAINT IF EXISTS finance_savings_plans_savings_goal_id_fk;
    ALTER TABLE finance.savings_plans ADD CONSTRAINT finance_savings_plans_savings_goal_id_fk
        FOREIGN KEY (savings_goal_id) REFERENCES finance.savings_goals(id) ON DELETE SET NULL;
END $$;
CREATE INDEX IF NOT EXISTS finance_savings_plans_savings_goal_idx
    ON finance.savings_plans (savings_goal_id) WHERE savings_goal_id IS NOT NULL;

-- Phase L WS-6: asset_class — Anlageklasse-Tag des Sparplans (== depot_holdings.asset_class-Format, ein
-- user-definierter target_allocation.blocks[].key). Bei Plan-Anlage erfasst (Agent schlägt vor), an jede
-- Ausführung vererbt (fn_book_savings_plan_execution → fn_book_stock_buy) → goal-/manuell-getaggte Positionen,
-- nie ein leerer Tag aus dem Sparplan-Cron. Additiv/nullable (NULL = ungetaggt, periodische null_tag-Meldung
-- als Netz) → Init-only (Muster asset_class/savings_goal_id/person_id, KEINE V-Migration). Format-CHECK = der
-- strukturelle Backstop (lowercase snake, KEIN FK — referenziert einen Plan-Sidecar-key); DROP+ADD idempotent.
-- ADD COLUMN IF NOT EXISTS deckt Bestands-DBs, die CREATE TABLE oben deckt frische.
ALTER TABLE finance.savings_plans ADD COLUMN IF NOT EXISTS asset_class varchar(40);
DO $$ BEGIN
    ALTER TABLE finance.savings_plans DROP CONSTRAINT IF EXISTS finance_savings_plans_asset_class_fmt;
    ALTER TABLE finance.savings_plans ADD CONSTRAINT finance_savings_plans_asset_class_fmt
        CHECK (asset_class IS NULL OR asset_class ~ '^[a-z0-9_]+$');
END $$;

-- Depot-Kalender (Live-Befund 2026-10-24): an welchen Monatstagen die Bank des Depots Sparplaene ausfuehrt.
--   NULL = unbekannt (fn_resolve_plan_schedule fragt bei woechentlich/zweimal monatlich einmal nach bzw. belegt
--   bekannte Banken per fn_broker_plan_days vor), '{}' = kein fester Kalender (echte 7-/14-Tage-Abstaende),
--   sonst die Tage (kanonisch, fn_valid_schedule_days). Gelernt im Sparplan-Write, gilt fuer alle weiteren Plaene
--   des Depots. Nur Depots (CHECK). Additiv/nullable -> Init-only; steht hier beim Sparplan-Block, weil es
--   ausschliesslich der Sparplan-Ableitung dient.
ALTER TABLE finance.accounts ADD COLUMN IF NOT EXISTS plan_execution_days smallint[];
DO $$ BEGIN
    ALTER TABLE finance.accounts DROP CONSTRAINT IF EXISTS finance_accounts_plan_execution_days_chk;
    ALTER TABLE finance.accounts ADD CONSTRAINT finance_accounts_plan_execution_days_chk CHECK (
        plan_execution_days IS NULL OR (
            account_type IN ('stocks_depot', 'crypto_depot')
            AND finance.fn_valid_schedule_days(plan_execution_days)));
END $$;

-- ============================================================
-- MULTI-MEMBER PERSON-SCOPING (WS-1) — additive person_id-Spalten + FK auf agent.persons.
-- Additiv/nullable (NULL = Haushalt/gemeinsam) -> Init-only (Muster asset_class/origin/package,
-- KEINE V-Migration). Der FK ON DELETE RESTRICT IST der strukturelle Verwaisungs-Schutz: eine
-- noch referenzierte Person ist aus `family` nicht entfernbar (der Reconcile-DELETE in
-- agent.fn_project_persons blockt -> der family-Write rollt atomar zurueck). agent.persons
-- existiert sicher (agent.persons_init.sql laeuft alphabetisch vor finance.tables_init.sql).
-- *_person_id ist seit WS-4 das EINZIGE Inhaber-Feld; die Freitext-Inhaber (account_holder/owner/
-- policyholder/borrower) sind abgeloest (finance:V006 droppt sie auf Bestands-DBs; die CREATE TABLEs
-- oben tragen sie auf frischen DBs gar nicht erst). NULL=Haushalt/gemeinsam (Joint-Konvention; kein
-- M2M noetig). Getaggt wird ueber die create_*/set_*-Tools (Personen-NAME -> core.fn_resolve_person
-- -> Slug); KEIN Auto-Backfill (Freitext-Name ist kein verlaesslicher Person-Key).
-- DROP+ADD CONSTRAINT = idempotent je Apply; ADD COLUMN IF NOT EXISTS deckt Bestands-DBs
-- (die CREATE TABLEs oben tragen den Endzustand fuer frische DBs).
-- ============================================================
DO $$
DECLARE
    r record;
    v_fk text;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('accounts',       'owner_person_id'),
            ('real_estate',    'owner_person_id'),
            ('pension',        'owner_person_id'),
            ('insurances',     'policyholder_person_id'),
            ('loans',          'borrower_person_id'),
            ('savings_goals',  'beneficiary_person_id'),
            ('savings_plans',  'beneficiary_person_id')
        ) AS t(tbl, col)
    LOOP
        v_fk := 'finance_' || r.tbl || '_' || r.col || '_fk';
        EXECUTE format('ALTER TABLE finance.%I ADD COLUMN IF NOT EXISTS %I text', r.tbl, r.col);
        EXECUTE format('ALTER TABLE finance.%I DROP CONSTRAINT IF EXISTS %I', r.tbl, v_fk);
        EXECUTE format(
            'ALTER TABLE finance.%I ADD CONSTRAINT %I FOREIGN KEY (%I) '
            || 'REFERENCES agent.persons(person_id) ON DELETE RESTRICT',
            r.tbl, v_fk, r.col);
    END LOOP;
END $$;

-- ============================================================
-- TRANSACTIONS
-- All account movements. Signed amounts: positive = credit, negative = debit.
-- category is a structured ENUM; use 'other' for unlisted types.
--
-- Loan pattern (two transactions per event):
--   disbursement: + on cash account, - on loan account
--   loan_payment: - on cash account (full annuity)
--   principal:    + on loan account (Tilgungsanteil only, reduces Restschuld)
--   settlement:   + on loan account (full payoff / refinancing)
--
-- Depot pattern (ONE transaction per trade, on settlement account only):
--   buy:   amount = -(shares*price + order_fee), shares = +units acquired, holding_id set, order_fee set
--   sell:  amount = +(shares*price - order_fee), shares = -units disposed,  holding_id set, order_fee set
--   The order fee is FOLDED INTO amount (it is part of the acquisition cost / proceeds) and additionally
--   stored in the order_fee column for tax/reporting. It is NEVER a separate 'fee' transaction.
--   category='fee' is reserved for trade-INDEPENDENT fees (depot/account keeping) only.
--   Depot account itself receives no transaction; its balance stays 0.
--   finance_depot_holdings.shares + average_purchase_price are trigger-maintained (never written directly):
--     shares = SUM(shares WHERE holding_id=X)
--     avg    = -SUM(amount) FILTER (category='buy') / SUM(shares) FILTER (category='buy')   [buys only]
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.transactions (
    id                   serial PRIMARY KEY,
    account_id           int NOT NULL REFERENCES finance.accounts(id),
    amount               numeric(12,2) NOT NULL,        -- signed: + credit, - debit
    transaction_date     date NOT NULL,
    category             finance.transaction_category NOT NULL DEFAULT 'other',
    description          varchar(255),
    recurring_payment_id int REFERENCES finance.recurring_payments(id),
    loan_id              int REFERENCES finance.loans(id),
    holding_id           int REFERENCES finance.depot_holdings(id), -- depot buy/sell: links to specific holding
    shares               numeric(18,8),                                   -- Anteilsdelta: + buy, - sell; NULL for non-depot
    order_fee            numeric(12,2),                                   -- buy/sell: order fee already folded into amount; kept separately for tax/reporting (Anschaffungsnebenkosten). NEVER booked as a separate 'fee' transaction.
    unit_price           numeric(20,8),                                   -- NUR Bestandsuebernahme (existing_position): der genannte Einstands-/Stueckpreis; fn_holding_avg_cost rechnet daraus statt aus dem cent-gerundeten amount (Rundungs-Paket 2026-10-23). NULL = normaler Kauf (Kostenbasis = |amount|, Broker-Konvention). CHECK finance_transactions_unit_price_chk (V019).
    interest_period_end  date,                                            -- Zins-Scheduler: das Perioden-ENDE, das diese Gutschrift abdeckt. Idempotenz- + booked-Erkennungs-Key (NICHT transaction_date — value_date/period_end sind bei Arrears entkoppelt). NULL = generische (Nicht-Scheduler-)Zinseinnahme (z. B. via fn_book_transaction) — fuer den Scheduler unsichtbar, zaehlt aber in die Zins-Basis.
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT finance_transactions_category_consistency CHECK (
        CASE category
            WHEN 'buy'          THEN holding_id IS NOT NULL AND shares > 0  AND amount < 0
            WHEN 'sell'         THEN holding_id IS NOT NULL AND shares < 0  AND amount > 0
            WHEN 'dividend'     THEN holding_id IS NOT NULL AND shares IS NULL AND amount > 0
            WHEN 'disbursement' THEN loan_id IS NOT NULL
            WHEN 'loan_payment' THEN loan_id IS NOT NULL AND amount < 0
            WHEN 'principal'    THEN loan_id IS NOT NULL AND amount > 0
            WHEN 'settlement'   THEN loan_id IS NOT NULL
            WHEN 'fee'          THEN amount < 0 AND shares IS NULL
            WHEN 'interest'     THEN amount <> 0 AND shares IS NULL AND holding_id IS NULL
            ELSE TRUE
        END
    )
);

-- Migration: add order_fee column on already-installed databases
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS order_fee numeric(12,2);
-- Rundungs-Paket 2026-10-23: Stueckpreis der Bestandsuebernahme (additiv, nullable; Backfill + CHECK in V019).
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS unit_price numeric(20,8);

-- Migration (Zins-Ausbau): interest_period_end additiv (Init-only, nullable, KEINE V-Migration).
-- BEWUSST kein harter CHECK "interest ⟹ interest_period_end IS NOT NULL": fn_book_transaction bucht
-- legitim generische category='interest'-Zeilen (Zinseinnahme ohne Scheduler-Periode) -> die blieben NULL
-- und ein Blanket-CHECK wuerde sie mit RAISE+Owner-Alert brechen. Der Scheduler keyt vollstaendig auf
-- interest_period_end (NULL = keine Scheduler-Gutschrift); fn_book_interest_occurrence setzt es immer.
-- Backfill: bestehende WS-5c-Scheduler-Gutschriften (Beschreibungs-Marker 'Zinsgutschrift <Datum>') hatten
-- period_end = transaction_date (kein Arrears in v1) -> scheduler-bewusst machen, damit der neue
-- booked-Check sie erkennt (sonst Doppel-Gutschrift-Risiko auf Bestands-DBs). Idempotent (IS-NULL-Guard);
-- auf die Scheduler-Beschreibung gescopt, damit generische Zinseinnahmen NULL bleiben.
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS interest_period_end date;
UPDATE finance.transactions SET interest_period_end = transaction_date
    WHERE category = 'interest' AND interest_period_end IS NULL AND description LIKE 'Zinsgutschrift %';

-- Migration (Monats-Check WP-A): recurring_due_date = Identitaet des Dauerauftrags-Vorkommens (die Faelligkeit, die
-- diese Buchung erledigt), entkoppelt vom Buchungsdatum (Ist-Datum laut Kontoauszug: Miete faellig 01.10., abgebucht
-- 02.10.). Muster interest_period_end (Init-only: Spalte + idempotenter Backfill + geguardeter CHECK). "Gebucht"
-- bleibt aus finance.transactions abgeleitet, keyt aber auf recurring_due_date statt transaction_date.
-- Backfill: Alt-Buchungen trugen transaction_date = due_date (alle Buch-fns buchten auf die Faelligkeit).
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS recurring_due_date date;
UPDATE finance.transactions SET recurring_due_date = transaction_date
    WHERE recurring_payment_id IS NOT NULL AND recurring_due_date IS NULL;

-- Default-Trigger: eine rp-Buchung OHNE Faelligkeit erledigt das Vorkommen an ihrem Buchungsdatum (Alt-Semantik;
-- deckt Direkt-INSERTs in Tests/Fixtures). Die Buch-fns setzen die Faelligkeit explizit. Einzeilig, kein Cross-Row
-- -> kein MVCC-Thema; der CHECK unten ist der Backstop.
CREATE OR REPLACE FUNCTION finance.default_recurring_due_date()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.recurring_payment_id IS NOT NULL AND NEW.recurring_due_date IS NULL THEN
        NEW.recurring_due_date := NEW.transaction_date;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_finance_default_recurring_due_date ON finance.transactions;
CREATE TRIGGER trg_finance_default_recurring_due_date
    BEFORE INSERT OR UPDATE OF recurring_payment_id ON finance.transactions
    FOR EACH ROW EXECUTE FUNCTION finance.default_recurring_due_date();

-- Monats-Check WP-C: Herkunft aus einem Kontoauszug (Ruecknahme des letzten Auszugs loescht genau diese Buchungen) und
-- Stueckzahl nur geschaetzt (Sparplan-Ausfuehrung aus dem Kontoauszug: Betrag / Kurs vom Ausfuehrungstag; der
-- Depot-Check korrigiert sie spaeter).
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS bank_statement_id int
    REFERENCES finance.bank_statements(id) ON DELETE SET NULL;
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS shares_estimated boolean NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_transactions_bank_statement ON finance.transactions (bank_statement_id)
    WHERE bank_statement_id IS NOT NULL;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'finance_transactions_recurring_due_chk') THEN
        ALTER TABLE finance.transactions ADD CONSTRAINT finance_transactions_recurring_due_chk
            CHECK (recurring_payment_id IS NULL OR recurring_due_date IS NOT NULL);
    END IF;
END $$;

-- Migration: refresh the category-consistency CHECK on already-installed databases
-- (DROP + ADD ensures upgrades from earlier versions of this constraint also pick up new rules)
DO $$ BEGIN
    ALTER TABLE finance.transactions
        DROP CONSTRAINT IF EXISTS finance_transactions_category_consistency;
    ALTER TABLE finance.transactions
        ADD CONSTRAINT finance_transactions_category_consistency CHECK (
            CASE category
                WHEN 'buy'          THEN holding_id IS NOT NULL AND shares > 0  AND amount < 0
                WHEN 'sell'         THEN holding_id IS NOT NULL AND shares < 0  AND amount > 0
                WHEN 'dividend'     THEN holding_id IS NOT NULL AND shares IS NULL AND amount > 0
                WHEN 'disbursement' THEN loan_id IS NOT NULL
                WHEN 'loan_payment' THEN loan_id IS NOT NULL AND amount < 0
                WHEN 'principal'    THEN loan_id IS NOT NULL AND amount > 0
                WHEN 'settlement'   THEN loan_id IS NOT NULL
                WHEN 'fee'          THEN amount < 0 AND shares IS NULL
                WHEN 'interest'     THEN amount <> 0 AND shares IS NULL AND holding_id IS NULL
                ELSE TRUE
            END
        );
END $$;

-- WS-B: der source_tx_id-FK von savings_goal_reserve_entries -> transactions wird HIER nachgezogen
-- (die Reserve-Journal-Tabelle steht weiter oben bei den savings_goals, transactions entsteht aber erst hier).
-- ON DELETE SET NULL: eine spaeter stornierte Kauf-Tx (Stage 2) soll das Journal nicht blocken — der
-- Provenance-Link entfaellt, die delta_native-Zahl bleibt (driftfreier Stand). DROP+ADD = idempotent je Apply.
DO $$ BEGIN
    ALTER TABLE finance.savings_goal_reserve_entries
        DROP CONSTRAINT IF EXISTS finance_savings_goal_reserve_entries_source_tx_fk;
    ALTER TABLE finance.savings_goal_reserve_entries
        ADD CONSTRAINT finance_savings_goal_reserve_entries_source_tx_fk
        FOREIGN KEY (source_tx_id) REFERENCES finance.transactions(id) ON DELETE SET NULL;
END $$;

-- Audit F5: real_estate.sale_tx_id -> transactions (zweite FK-Ausnahme neben source_tx_id; s. .claude/rules/sql.md).
-- fn_void_transaction setzt eine verkaufte Immobilie zurueck auf 'active', wenn genau diese Erloes-Tx storniert
-- wird; ON DELETE SET NULL raeumt den Link danach (Hard-Delete-Ledger). DROP+ADD = idempotent je Apply.
DO $$ BEGIN
    ALTER TABLE finance.real_estate DROP CONSTRAINT IF EXISTS finance_real_estate_sale_tx_fk;
    ALTER TABLE finance.real_estate ADD CONSTRAINT finance_real_estate_sale_tx_fk
        FOREIGN KEY (sale_tx_id) REFERENCES finance.transactions(id) ON DELETE SET NULL;
END $$;

-- Backfill Alt-Verkaeufe (vor sale_tx_id): eindeutiger Match auf die Erloes-Buchung, die fn_sell_real_estate
-- schreibt (Beschreibung + Betrag = Verkaufspreis + Datum = Verkaufsdatum). Mehrdeutig/kein Treffer -> bleibt NULL
-- (nicht zuruecksetzbar). Idempotent (nur sale_tx_id IS NULL).
UPDATE finance.real_estate r
SET sale_tx_id = m.tx_id
FROM (
    SELECT r2.id AS re_id, min(t.id) AS tx_id
    FROM finance.real_estate r2
    JOIN finance.transactions t
      ON t.description = 'Verkaufserlös ' || r2.name
     AND t.amount = r2.current_value
     AND t.transaction_date = r2.value_updated_at
    WHERE r2.status = 'sold' AND r2.sale_tx_id IS NULL
    GROUP BY r2.id
    HAVING count(*) = 1
) m
WHERE r.id = m.re_id;

-- ============================================================
-- ACCOUNT BALANCES
-- Current balance per account, auto-maintained by trigger.
-- Initialized to 0 when account is created (via trigger below).
-- Loan accounts carry negative balances = current Restschuld.
-- ============================================================

CREATE TABLE IF NOT EXISTS finance.account_balances (
    account_id int PRIMARY KEY REFERENCES finance.accounts(id),
    balance    numeric(12,2) NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- STRUKTURELLE HAERTUNG (Defense-in-Depth)
-- Leitlinie: Invarianten so tief wie moeglich verankern -- DB-strukturell (Constraint/FK/Trigger)
-- ist Gesetz; fn_* ist atomare Durchsetzung; Tool/Description sind nur Komfort und driften.
-- Die fn_*-Guards liefern weiterhin die freundliche {ok:false}-Meldung; diese Constraints sind das
-- Netz, falls eine fn je umgangen wird (Direktzugriff, Bug, kuenftiger Umbau). Idempotent.
-- (Siehe .claude/rules/sql.md "Integritaets-Konventionen".)
-- ============================================================

-- Multi-Leg-Gruppierung: ein Write-fn = eine group_id = ein atomares Void (transfer- + loan-Paare).
-- Loest die "Transfer-Beine haengen nur an der Tool-Description"-Schwachstelle strukturell auf.
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS group_id uuid;
CREATE INDEX IF NOT EXISTS idx_transactions_group
    ON finance.transactions (group_id) WHERE group_id IS NOT NULL;

-- Bestandsuebernahme-Form (Backstop zu fn_book_stock_buy existing_position): die Gegenbuchung ist immer
-- positiv, gehoert per group_id zu ihrem Kauf (ein Void = beide Zeilen) und traegt keine Holding/Stueck.
-- category::text statt Enum-Literal: der CHECK entsteht so auch in derselben Transaktion wie das ADD VALUE.
DO $$ BEGIN
    ALTER TABLE finance.transactions DROP CONSTRAINT IF EXISTS finance_transactions_position_takeover_shape;
    ALTER TABLE finance.transactions ADD CONSTRAINT finance_transactions_position_takeover_shape CHECK (
        category::text <> 'position_takeover'
        OR (amount > 0 AND group_id IS NOT NULL AND holding_id IS NULL AND shares IS NULL)
    );
END $$;

-- Umbuchungs-Gruppierung (Backstop zu fn_book_transaction, das 'transfer' gar nicht annimmt, und zu
-- fn_book_transfer/fn_book_recurring_transfer, die beide Beine mit EINER group_id schreiben): eine transfer-Zeile
-- ohne group_id waere ein einbeiniger Transfer, den fn_void_transaction nicht als Paar stornieren kann.
-- NOT VALID nur beim ersten Anlegen (Altbestand): finance:V022 traegt die group_id nach und VALIDATEt. KEIN DROP+ADD
-- je Apply (das setzte den Constraint jedes Mal wieder auf NOT VALID).
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'finance_transactions_transfer_grouped') THEN
        ALTER TABLE finance.transactions ADD CONSTRAINT finance_transactions_transfer_grouped
            CHECK (category::text <> 'transfer' OR group_id IS NOT NULL) NOT VALID;
    END IF;
END $$;

-- Oversell-Backstop: ein Depot-Bestand darf nie negativ werden (der shares-Trigger schreibt shares;
-- ein Oversell-Void laesst den Recompute am CHECK hart scheitern -> Rollback).
DO $$ BEGIN
    ALTER TABLE finance.depot_holdings DROP CONSTRAINT IF EXISTS finance_depot_holdings_shares_nonneg;
    ALTER TABLE finance.depot_holdings ADD CONSTRAINT finance_depot_holdings_shares_nonneg CHECK (shares >= 0);
END $$;

-- Positive-Wert-Backstops (spiegeln die bestehenden fn-Guards 1:1 -> kein Verhaltensbruch).
DO $$ BEGIN
    ALTER TABLE finance.loans         DROP CONSTRAINT IF EXISTS finance_loans_amount_pos;
    ALTER TABLE finance.loans         ADD  CONSTRAINT finance_loans_amount_pos CHECK (original_amount > 0);
    -- Auszahlung auf ein eigenes Konto nur bei frischem Kredit mit Kreditbetrag (Spiegel des fn_create_loan-Guards).
    ALTER TABLE finance.loans         DROP CONSTRAINT IF EXISTS finance_loans_disbursement_needs_amount;
    ALTER TABLE finance.loans         ADD  CONSTRAINT finance_loans_disbursement_needs_amount
        CHECK (disbursement_account_id IS NULL OR original_amount IS NOT NULL);
    ALTER TABLE finance.savings_goals DROP CONSTRAINT IF EXISTS finance_savings_goals_target_pos;
    ALTER TABLE finance.savings_goals ADD  CONSTRAINT finance_savings_goals_target_pos CHECK (target_amount > 0);
    ALTER TABLE finance.real_estate   DROP CONSTRAINT IF EXISTS finance_real_estate_value_nonneg;
    ALTER TABLE finance.real_estate   ADD  CONSTRAINT finance_real_estate_value_nonneg CHECK (current_value IS NULL OR current_value >= 0);
    ALTER TABLE finance.pension       DROP CONSTRAINT IF EXISTS finance_pension_value_nonneg;
    ALTER TABLE finance.pension       ADD  CONSTRAINT finance_pension_value_nonneg CHECK (current_value IS NULL OR current_value >= 0);
END $$;

-- Multi-Waehrung: currency-Spalten an die Waehrungs-Dimension binden (FK = Tippfehler-Schutz).
-- finance_currencies enthaelt EUR (init-geseedet); alle weiteren Waehrungen registriert fn_ensure_currency on-demand. Idempotent.
DO $$ BEGIN
    ALTER TABLE finance.accounts        DROP CONSTRAINT IF EXISTS finance_accounts_currency_fk;
    ALTER TABLE finance.accounts        ADD  CONSTRAINT finance_accounts_currency_fk
        FOREIGN KEY (currency) REFERENCES finance.currencies(code);
    ALTER TABLE finance.depot_holdings  DROP CONSTRAINT IF EXISTS finance_depot_holdings_currency_fk;
    ALTER TABLE finance.depot_holdings  ADD  CONSTRAINT finance_depot_holdings_currency_fk
        FOREIGN KEY (currency) REFERENCES finance.currencies(code);
END $$;

-- Multi-Waehrung: realisierter Umrechnungskurs auf Cross-Currency-Beinen (z. B. EUR->KRW-Transfer).
-- Bei gleicher Waehrung NULL. Tx-Waehrung selbst wird aus dem Konto abgeleitet (keine redundante Spalte).
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS fx_rate numeric(20,10);

-- WS-A Phase S: Ziel-Tag (Reserve-Envelope, YNAB/Actual-Modell). Markiert die RESERVE-Bewegungen EINES
-- Sparziels — das Haben-(Ziel-)Bein der Sparrate-Umbuchung, Einmal-Summen, Entnahmen — ueber BELIEBIG viele
-- Konten (Tagesgeld + Depot). savings_goal_progress summiert sie VORZEICHEN-ROH (Reserve-Zufluss +,
-- Entnahme/Reserve-Abfluss -) => eine Entnahme senkt den Fortschritt automatisch. NUR das Reserve-Bein wird
-- getaggt (nie beide Transfer-Beine -> sonst Netto-0). ON DELETE SET NULL: ein geloeschtes Ziel laesst die
-- Buchungen historisch stehen (kein Tx-Verlust).
ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS savings_goal_id int
    REFERENCES finance.savings_goals(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_transactions_savings_goal
    ON finance.transactions (savings_goal_id) WHERE savings_goal_id IS NOT NULL;

-- ============================================================
-- INTEGRITAETS-HAERTUNG (Stufe 4)
-- ============================================================

-- (a) updated_at auf mutable Entitaeten + generischer Touch-Trigger. Liefert "wann zuletzt geaendert"
--     fuer die set_*/close_*-Pfade (created_at allein deckte das nicht ab; "Chat-History als Audit" haelt nicht).
CREATE OR REPLACE FUNCTION finance.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'accounts','loans','insurances','pension',
        'real_estate','savings_goals','recurring_payments','savings_plans'
    ] LOOP
        EXECUTE format('ALTER TABLE finance.%I ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()', t);
        -- Bestands-DB: der per SET SCHEMA mitgezogene alte Trigger trg_finance_<t>_touch wird hier
        -- mit-aufgeraeumt (sonst feuerten nach dem Rename zwei Touch-Trigger; idempotent harmlos, aber unsauber).
        EXECUTE format('DROP TRIGGER IF EXISTS trg_finance_%s_touch ON finance.%I', t, t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_touch ON finance.%I', t, t);
        EXECUTE format('CREATE TRIGGER trg_%s_touch BEFORE UPDATE ON finance.%I FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at()', t, t);
    END LOOP;
END $$;

-- (b) entity <-> recurring_payment Exklusivitaet: eine recurring_payment darf je Tabelle nur EINER
--     Entitaet gehoeren (Partial-UNIQUE; verhindert die wahrscheinlichste Fehlanlage = doppelte Verknuepfung).
--     (Cross-Table-Exklusivitaet via Trigger bewusst NICHT — MVCC-Races; siehe Integritaets-Konventionen.)
CREATE UNIQUE INDEX IF NOT EXISTS finance_insurances_rp_uq
    ON finance.insurances (recurring_payment_id) WHERE recurring_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS finance_loans_rp_uq
    ON finance.loans (recurring_payment_id) WHERE recurring_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS finance_pension_rp_uq
    ON finance.pension (recurring_payment_id) WHERE recurring_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS finance_savings_goals_rp_uq
    ON finance.savings_goals (recurring_payment_id) WHERE recurring_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS finance_savings_plans_rp_uq
    ON finance.savings_plans (recurring_payment_id) WHERE recurring_payment_id IS NOT NULL;

-- (b2) Doppelbuchungs-Riegel (WP-1, arch-challenge D-dedup): struktureller Backstop gegen das TOCTOU-Race der
--     EXISTS-vor-INSERT-Idempotenz (zwei async Bucher: Folge-Tag-Cron vs. Agent-Override). Die Buchungs-fns
--     behalten den freundlichen EXISTS-Guard + ON CONFLICT DO NOTHING (Race verloren -> {ok:false}); DIESE
--     partiellen UNIQUE-Indizes sind das Gesetz (Muster (b) oben + die Skip-fns ON CONFLICT). Cross-row-
--     Invariante ueber Constraint, NICHT Gate-Trigger (MVCC-Race, s. Integritaets-Konventionen).
--   RECURRING: 3-spaltig (rp_id, recurring_due_date, account_id) — ein interner Transfer bucht ZWEI Beine mit
--     identischem (rp_id, due), unterschieden NUR durch account_id (Soll v_from / Haben v_to); ein 2-spaltiger Index
--     braeche jeden Transfer. Deckt recurring_occurrence + recurring_transfer + Kreditrate + Sparplan-Kauf. Keyt auf
--     die FAELLIGKEIT (Monats-Check WP-A), nicht aufs Buchungsdatum; der Vorgaenger auf transaction_date
--     (finance_transactions_recurring_occurrence_uq) faellt per finance:V015.
CREATE UNIQUE INDEX IF NOT EXISTS finance_transactions_recurring_due_uq
    ON finance.transactions (recurring_payment_id, recurring_due_date, account_id)
    WHERE recurring_payment_id IS NOT NULL;
--   INTEREST: (account_id, period_end) NUR fuer Scheduler-Zins-Tx (period_end NOT NULL); generische Zins-
--     einnahmen via fn_book_transaction tragen period_end NULL und bleiben ausserhalb des Arbiters (bookbar).
CREATE UNIQUE INDEX IF NOT EXISTS finance_transactions_interest_occurrence_uq
    ON finance.transactions (account_id, interest_period_end)
    WHERE category = 'interest' AND interest_period_end IS NOT NULL;

-- (c) Void-Audit: Hard-DELETE einer Buchung haelt das geloeschte Payload als JSONB fest (in derselben
--     Transaktion von fn_void_transaction geschrieben). Schliesst die "keine Change-Historie"-Luecke,
--     ohne einen vollen immutable Ledger (bewusstes Nicht-Ziel). Kein FK (die Tx ist danach weg).
CREATE TABLE IF NOT EXISTS finance.transaction_audit (
    id             serial PRIMARY KEY,           -- SERIAL = konsistent mit dem uebrigen Schema (IDENTITY ist die Forward-Konvention)
    transaction_id int NOT NULL,                 -- urspruengliche finance_transactions.id (kein FK, Zeile geloescht)
    payload        jsonb NOT NULL,               -- vollstaendige geloeschte Zeile (to_jsonb)
    voided_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- ONBOARDING-FORTSCHRITT (WS-B3 DRY-Onboarding O3) — paket-besessene Daten
--   Homogenes Muster zur Core-Referenzform agent.guide_onboarding_state (gleiche Spalten): je
--   Sektion ein Tri-State ('unknown'/'completed'/'skipped' als text+CHECK — KEIN geteilter
--   Cross-Schema-ENUM, arch-challenge D4). Finance besitzt seine 5 Sektionen (geseedet von
--   seed_data.sh aus packages/finance/onboarding/sections.json — KEIN Seed hier, die Tabelle
--   bleibt im Init leer). Gelesen/geschrieben ueber die Core-Schnittstelle core.fn_onboarding_status
--   / core.fn_set_onboarding_section (DRY, paket-schluessel-parametrisiert): finance_rw schreibt
--   direkt (eigenes Schema, INVOKER), finance_ro liest ueber die publizierte SECURITY-DEFINER-fn (D10).
-- ============================================================
CREATE TABLE IF NOT EXISTS finance.onboarding_state (
    section_key text PRIMARY KEY,
    ord         int  NOT NULL,
    label       text NOT NULL,
    status      text NOT NULL DEFAULT 'unknown' CHECK (status IN ('unknown', 'completed', 'skipped')),
    skipped_at  timestamptz,                          -- ALTLAST, ungenutzt (ableitbar aus status+status_changed_at): bleibt nur, weil core:V003 sie beim frischen Bootstrap liest; finance:V029 droppt sie
    updated_at  timestamptz NOT NULL DEFAULT now()
);
-- Roter Faden (Nachfassen): Zeitpunkt der letzten STATUS-Aenderung, gesetzt nur von core.fn_set_onboarding_section
-- (Konvention jedes <pkg>.onboarding_state, s. agent.guide_init.sql).
ALTER TABLE finance.onboarding_state ADD COLUMN IF NOT EXISTS status_changed_at timestamptz NOT NULL DEFAULT now();

DROP TRIGGER IF EXISTS trg_onboarding_state_touch ON finance.onboarding_state;
CREATE TRIGGER trg_onboarding_state_touch BEFORE UPDATE ON finance.onboarding_state
    FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_transactions_account_date
    ON finance.transactions (account_id, transaction_date);

CREATE INDEX IF NOT EXISTS idx_transactions_recurring
    ON finance.transactions (recurring_payment_id)
    WHERE recurring_payment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_holding
    ON finance.transactions (holding_id)
    WHERE holding_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recurring_payments_account_validity
    ON finance.recurring_payments (account_id, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_interest_rates_account_validity
    ON finance.account_interest_rates (account_id, valid_from);

CREATE INDEX IF NOT EXISTS idx_depot_holdings_account
    ON finance.depot_holdings (account_id);

-- WS-B: idx_savings_goal_allocations_goal entfaellt (Tabelle via finance:V008 retired); die Reserve-Journal-
-- Indizes liegen inline an der savings_goal_reserve_entries-CREATE TABLE (goal_idx + account_idx).

CREATE INDEX IF NOT EXISTS idx_savings_plans_depot
    ON finance.savings_plans (depot_id);

CREATE INDEX IF NOT EXISTS idx_savings_plans_rp
    ON finance.savings_plans (recurring_payment_id);

-- ============================================================
-- TRIGGER: Initialize balance row when account is created
-- ============================================================

CREATE OR REPLACE FUNCTION finance.init_finance_balance()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO finance.account_balances (account_id, balance, updated_at)
    VALUES (NEW.id, 0, NOW())
    ON CONFLICT DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_account_balance_init ON finance.accounts;
CREATE TRIGGER trg_finance_account_balance_init
    AFTER INSERT ON finance.accounts
    FOR EACH ROW EXECUTE FUNCTION finance.init_finance_balance();

-- ============================================================
-- TRIGGER: Auto-update balance after any transaction change
-- Uses full SUM recalculation for consistency (no drift on corrections).
-- On UPDATE with changed account_id, recalculates both old and new account.
-- Audit Paket 2 (Punkt 12): die Saldo-Zeile wird ZUERST gesperrt (FOR UPDATE), DANN summiert. Vorher lief die Summe
-- vor dem Konflikt-Lock des Upserts -> zwei parallele Buchungen (Cron || Chat) summierten je ohne die andere, der
-- zweite Upsert ueberschrieb den Saldo (Lost Update). In READ COMMITTED nimmt jede Anweisung einer plpgsql-Funktion
-- einen neuen Snapshot -> die Summe NACH dem Warten auf die Sperre sieht die committete Parallel-Buchung.
-- Deadlocks (zwei gegenlaeufige Transfers sperren A,B bzw. B,A) waren schon vorher moeglich und sind ein lauter
-- Abbruch mit Rollback, kein stiller Fehler -> bewusst akzeptiert.
-- ============================================================

CREATE OR REPLACE FUNCTION finance.update_finance_balance()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_account_id INT;
BEGIN
    v_account_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.account_id ELSE NEW.account_id END;

    -- Zeile sicherstellen (Altkonto ohne Saldo-Zeile), sperren, dann summieren.
    INSERT INTO finance.account_balances (account_id, balance, updated_at)
    VALUES (v_account_id, 0, NOW())
    ON CONFLICT (account_id) DO NOTHING;
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_account_id FOR UPDATE;
    UPDATE finance.account_balances
    SET balance    = (SELECT COALESCE(SUM(amount), 0) FROM finance.transactions WHERE account_id = v_account_id),
        updated_at = NOW()
    WHERE account_id = v_account_id;

    -- If account_id changed on UPDATE, recalculate the old account too (gleiches Sperren-dann-Summieren)
    IF TG_OP = 'UPDATE' AND OLD.account_id <> NEW.account_id THEN
        PERFORM 1 FROM finance.account_balances WHERE account_id = OLD.account_id FOR UPDATE;
        UPDATE finance.account_balances
        SET balance    = (SELECT COALESCE(SUM(amount), 0) FROM finance.transactions WHERE account_id = OLD.account_id),
            updated_at = NOW()
        WHERE account_id = OLD.account_id;
    END IF;

    -- Phase Notify: Reserve-Breach-Latch RE-ARMEN, sobald das Konto wieder >= der fuer Sparziele reservierten
    -- Linie liegt. account_reserve_status liest den soeben ge-upserteten Saldo (oben) -> konsistent in
    -- derselben Transaktion; .breach ist false, wenn balance>=reserved ODER reserved=0. Der Trigger feuert auf
    -- ALLEN Tx-Schreibpfaden (auch Zins/Dividende/Kreditrate) -> der Re-Arm ist pfad-unabhaengig (deshalb hier
    -- und nicht in den 2 Fold-fns). Nur das primaere Konto; der OLD.account_id-Zweig (Tx-Konto-Wechsel) bleibt
    -- unbehandelt = heute toter Pfad (keine fn verschiebt eine Tx zwischen Konten), bewusst YAGNI.
    -- core.fn_notify_resolve ist No-op ohne Latch-Zeile (Erholung ohne je gefeuerten Breach).
    IF NOT COALESCE((SELECT s.breach FROM finance.account_reserve_status s WHERE s.account_id = v_account_id), false) THEN
        PERFORM core.fn_notify_resolve('finance', 'reserve_breach:' || v_account_id);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_balance_update ON finance.transactions;
CREATE TRIGGER trg_finance_balance_update
    AFTER INSERT OR UPDATE OR DELETE ON finance.transactions
    FOR EACH ROW EXECUTE FUNCTION finance.update_finance_balance();

-- ============================================================
-- TRIGGER: Reject transactions on closed accounts
-- Hard guard so the agent cannot accidentally book against a
-- closed account. Raised as exception with the account id.
-- ============================================================

CREATE OR REPLACE FUNCTION finance.reject_closed_account_txn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT status FROM finance.accounts WHERE id = NEW.account_id) = 'closed' THEN
        RAISE EXCEPTION 'Account % is closed — no new transactions allowed', NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_reject_closed_account ON finance.transactions;
CREATE TRIGGER trg_finance_reject_closed_account
    BEFORE INSERT ON finance.transactions
    FOR EACH ROW EXECUTE FUNCTION finance.reject_closed_account_txn();

-- ============================================================
-- TRIGGER: Kontotyp-Backstop (Audit Paket 2, Punkt 7)
-- Ein Depot-Konto traegt nie eine Buchung (Kauf/Verkauf/Dividende laufen ueber das Verrechnungskonto; eine Buchung
-- auf dem Depot verschwaende still aus dem Vermoegen). Ein Kreditkonto bucht nur mit loan_id (Kredit-Tools) — sonst
-- entstuende eine Restschuld ohne Kredit. Die fn-Guards (finance.fn_bookable_account_reason) liefern vorher das
-- freundliche {ok:false}; dieser Trigger faengt jeden anderen Schreibpfad. SICHER als BEFORE-INSERT-Trigger, weil
-- account_type immutable ist (kein UPDATE-Pfad/Multi-Row/MVCC; Muster reject_interest_rate_ineligible_type).
-- ============================================================

CREATE OR REPLACE FUNCTION finance.reject_account_type_txn()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_type finance.account_type;
BEGIN
    SELECT account_type INTO v_type FROM finance.accounts WHERE id = NEW.account_id;
    IF v_type IN ('stocks_depot', 'crypto_depot') THEN
        RAISE EXCEPTION 'Account % is a depot account — transactions belong on its settlement account.', NEW.account_id;
    END IF;
    IF v_type = 'loan' AND NEW.loan_id IS NULL THEN
        RAISE EXCEPTION 'Account % is a loan account — transactions there need a loan_id (loan tools only).', NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_reject_account_type_txn ON finance.transactions;
CREATE TRIGGER trg_finance_reject_account_type_txn
    BEFORE INSERT ON finance.transactions
    FOR EACH ROW EXECUTE FUNCTION finance.reject_account_type_txn();

-- ============================================================
-- TRIGGER: Reject interest-rate rows on non-interest-bearing account types (Phase Z WS-Z4)
-- DB-ist-Gesetz-Backstop: nur cash/fixed_deposit/p2p duerfen eine account_interest_rates-Zeile tragen
-- (= finance.fn_interest_eligible_account_type, die EINE Adresse der Allowlist). Die fn-Guards in
-- fn_set_account_interest / fn_book_interest_occurrence liefern die freundliche {ok:false}-Meldung VOR
-- diesem Trigger; der Trigger faengt jeden Nicht-fn-Schreibpfad (inkl. fn_create_account, das kein
-- ok-Feld hat). SICHER als reiner BEFORE-INSERT-Trigger, weil account_type immutable ist (fn_set_account
-- aendert ihn nie) -> kein UPDATE-Pfad/Multi-Row/MVCC. fn_interest_eligible_account_type ist weiter oben im
-- SELBEN Init definiert (nicht R__) -> existiert bei CREATE TRIGGER bereits; genau dieser Init-Verweis
-- erzwingt ihre Init-Platzierung (eine R__-fn waere hier noch nicht da). Die Trigger-fn selbst ist plpgsql.
-- ============================================================

CREATE OR REPLACE FUNCTION finance.reject_interest_rate_ineligible_type()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT finance.fn_interest_eligible_account_type(
            (SELECT account_type FROM finance.accounts WHERE id = NEW.account_id)) THEN
        RAISE EXCEPTION 'Interest rates apply only to cash, fixed-deposit and P2P accounts (account % is not eligible).', NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_reject_interest_rate_ineligible ON finance.account_interest_rates;
CREATE TRIGGER trg_finance_reject_interest_rate_ineligible
    BEFORE INSERT ON finance.account_interest_rates
    FOR EACH ROW EXECUTE FUNCTION finance.reject_interest_rate_ineligible_type();

-- ============================================================
-- TRIGGER: Keep finance_depot_holdings.shares in sync with transactions
-- Source of truth = SUM(finance_transactions.shares WHERE holding_id = X).
-- The agent never writes finance_depot_holdings.shares directly.
-- Fires on INSERT/UPDATE/DELETE; handles holding_id changes on UPDATE.
-- ============================================================

CREATE OR REPLACE FUNCTION finance.update_holding_shares()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_holding_id INT;
BEGIN
    v_holding_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.holding_id ELSE NEW.holding_id END;

    IF v_holding_id IS NOT NULL THEN
        UPDATE finance.depot_holdings
        SET shares = (
                SELECT COALESCE(SUM(shares), 0)
                FROM finance.transactions
                WHERE holding_id = v_holding_id
                  AND shares IS NOT NULL
            ),
            updated_at = NOW()
        WHERE id = v_holding_id;
    END IF;

    -- If holding_id changed on UPDATE, recompute the old holding as well
    IF TG_OP = 'UPDATE' AND OLD.holding_id IS DISTINCT FROM NEW.holding_id AND OLD.holding_id IS NOT NULL THEN
        UPDATE finance.depot_holdings
        SET shares = (
                SELECT COALESCE(SUM(shares), 0)
                FROM finance.transactions
                WHERE holding_id = OLD.holding_id
                  AND shares IS NOT NULL
            ),
            updated_at = NOW()
        WHERE id = OLD.holding_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_update_holding_shares ON finance.transactions;
CREATE TRIGGER trg_finance_update_holding_shares
    AFTER INSERT OR UPDATE OR DELETE ON finance.transactions
    FOR EACH ROW EXECUTE FUNCTION finance.update_holding_shares();

-- ============================================================
-- FUNCTION: fn_holding_avg_cost — gleitender Durchschnittskaufpreis (Durchschnittskostenmethode)
--   EINE Formel-Adresse fuer Trigger + Backfill (Inline-Baseline, weil trigger-gekoppelt). Replay der
--   buy/sell-Zeilen einer Holding chronologisch (transaction_date, id):
--     buy : Kosten += |amount| (Order-Gebuehr ist in amount gefaltet -> Teil der Kostenbasis), Stueck += shares
--     sell: Kosten anteilig reduzieren (Durchschnitt bleibt gleich; Sell-Gebuehren beruehren ihn nie)
--   Bestand <= 0 (Vollverkauf, rueckdatierter Verkauf, Void eines Kaufs aus der Mitte) -> Kostenbasis auf 0;
--   ein Nachkauf startet neu (Audit F3: vorher summierte die Formel ALLE Kaeufe aller Zeiten ->
--   10@100, -5, +5@200 ergab 133.33 statt 150). Nie Division durch <= 0. Bei Bestand 0 bleibt der LETZTE
--   Durchschnitt sichtbar; NULL nur, wenn die Holding nie einen Kauf hatte. Intern volle Genauigkeit,
--   gerundet wird nur das Ergebnis (8 Stellen = Spaltenpraezision numeric(20,8), Audit Paket 2 / V013).
--   Kostenbasis je Kauf: Bestandsuebernahme mit unit_price -> shares x unit_price + order_fee (der genannte
--   Einstand, ungerundet; vorher 3322.20/0.06127493 = 54217.93 statt 54218, Rundungs-Paket 2026-10-23); sonst
--   |amount| = der abgebuchte Cent-Betrag inkl. Gebuehr (Broker-Konvention).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_holding_avg_cost(p_holding_id int)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tx     RECORD;
    v_shares NUMERIC := 0;
    v_cost   NUMERIC := 0;
    v_avg    NUMERIC;
BEGIN
    FOR v_tx IN
        SELECT category, shares,
               CASE WHEN unit_price IS NOT NULL THEN shares * unit_price + COALESCE(order_fee, 0) ELSE abs(amount) END AS cost
        FROM finance.transactions
        WHERE holding_id = p_holding_id
          AND category IN ('buy', 'sell')
          AND shares IS NOT NULL
        ORDER BY transaction_date, id
    LOOP
        IF v_tx.category = 'buy' THEN
            IF v_shares <= 0 THEN
                v_shares := 0;
                v_cost   := 0;
            END IF;
            v_shares := v_shares + v_tx.shares;
            v_cost   := v_cost + v_tx.cost;
            v_avg    := v_cost / v_shares;
        ELSE
            IF v_shares + v_tx.shares <= 0 THEN
                v_cost := 0;
            ELSE
                v_cost := v_cost * (v_shares + v_tx.shares) / v_shares;
            END IF;
            v_shares := v_shares + v_tx.shares;   -- sell-shares sind negativ
        END IF;
    END LOOP;
    RETURN ROUND(v_avg, 8);
END;
$$;

-- ============================================================
-- TRIGGER: Keep finance_depot_holdings.average_purchase_price in sync
-- Gleitender Durchschnitt via finance.fn_holding_avg_cost (s. dort). Der Agent schreibt
-- average_purchase_price nie direkt. Mirrors the shares trigger (INSERT/UPDATE/DELETE + holding_id changes).
-- ============================================================

CREATE OR REPLACE FUNCTION finance.update_holding_avg_price()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_holding_id INT;
BEGIN
    v_holding_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.holding_id ELSE NEW.holding_id END;

    IF v_holding_id IS NOT NULL THEN
        UPDATE finance.depot_holdings
        SET average_purchase_price = finance.fn_holding_avg_cost(v_holding_id),
            updated_at = NOW()
        WHERE id = v_holding_id;
    END IF;

    -- If holding_id changed on UPDATE, recompute the old holding as well
    IF TG_OP = 'UPDATE' AND OLD.holding_id IS DISTINCT FROM NEW.holding_id AND OLD.holding_id IS NOT NULL THEN
        UPDATE finance.depot_holdings
        SET average_purchase_price = finance.fn_holding_avg_cost(OLD.holding_id),
            updated_at = NOW()
        WHERE id = OLD.holding_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_finance_update_holding_avg_price ON finance.transactions;
CREATE TRIGGER trg_finance_update_holding_avg_price
    AFTER INSERT OR UPDATE OR DELETE ON finance.transactions
    FOR EACH ROW EXECUTE FUNCTION finance.update_holding_avg_price();

-- Backfill: average_purchase_price aller Holdings mit Transaktionen per gleitendem Durchschnitt neu
-- rechnen (korrigiert Bestandswerte der frueheren Buy-only-Formel nach Nachkauf). Idempotent; nur
-- Zeilen, deren Wert abweicht (kein Leer-UPDATE je Apply).
UPDATE finance.depot_holdings h
SET average_purchase_price = finance.fn_holding_avg_cost(h.id)
WHERE EXISTS (SELECT 1 FROM finance.transactions t WHERE t.holding_id = h.id)
  AND h.average_purchase_price IS DISTINCT FROM finance.fn_holding_avg_cost(h.id);

-- ============================================================
-- FUNCTION: fn_to_eur_unrounded — wie fn_to_eur, aber OHNE Cent-Rundung (Rundungs-Paket 2026-10-23)
-- Fuer Einheitswerte: Stueckpreis in Fremdwaehrung -> EUR (fn_statement_prepare), Puffer-Umrechnung
-- (fn_account_outlook), EUR-Zwischenwert einer Waehrungs-Ueberweisung (fn_book_recurring_transfer, rundet
-- danach EINMAL). Dieselbe Kurs-Suche wie fn_to_eur (EINE Adresse: fn_to_eur rundet nur dieses Ergebnis).
-- EUR -> unveraendert; fehlt jeder Kurs -> NULL. Inline-Baseline VOR fn_to_eur (deren sql-Body ruft sie).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_to_eur_unrounded(
    p_amount   numeric,
    p_currency char(3),
    p_as_of    date DEFAULT current_date
) RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_amount IS NULL   THEN NULL
        WHEN p_currency = 'EUR' THEN p_amount
        ELSE p_amount / NULLIF((
                 SELECT r.rate
                 FROM finance.fx_rates r
                 WHERE r.base_currency = 'EUR'
                   AND r.quote_currency = p_currency
                 ORDER BY (r.as_of <= p_as_of) DESC, r.as_of DESC
                 LIMIT 1
             ), 0)
    END;
$$;

-- ============================================================
-- FUNCTION: fn_to_eur — Multi-Waehrungs-Konversion in die Reporting-Basis EUR
-- Konvertiert einen Betrag aus seiner Native-Waehrung nach EUR ueber finance_fx_rates.
-- EUR -> unveraendert; sonst betrag / (EZB-Kurs base=EUR/quote=ccy), auf Cent gerundet. As-of-Lookup: juengster
-- Kurs mit as_of <= Stichtag, sonst Fallback auf den juengsten verfuegbaren. Fehlt JEDER Kurs -> NULL.
-- STABLE (liest Tabelle) -> in Views nutzbar, NICHT in GENERATED-Spalten. Hier inline-Baseline
-- (KEINE R__-Repeatable), weil die Roll-up-Views (packages/finance/db/migrations/R__finance_views.sql, Phase 3) sie
-- referenzieren -> der Baseline-Helfer muss vor Phase 3 existieren.
-- Cent-Rundung NUR fuer Betraege: Einheitswerte (Stueckpreis, "1 Einheit in EUR") rechnen mit
-- fn_to_eur_unrounded (darueber) — vorher wurde ein Kurs von 0.20 USD zu 0.19 EUR und 1 KRW zu 0.00 EUR.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_to_eur(
    p_amount   numeric,
    p_currency char(3),
    p_as_of    date DEFAULT current_date
) RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_amount IS NULL   THEN NULL
        WHEN p_currency = 'EUR' THEN p_amount
        ELSE ROUND(finance.fn_to_eur_unrounded(p_amount, p_currency, p_as_of), 2)
    END;
$$;

-- ============================================================
-- RESTSCHULD-VORSCHAU (WP2 "Finanzen schlank") -- Lese-Helfer ueber die Raten-Kette, IM INIT (loan_overview nutzt sie;
-- R__finance_views laeuft vor allen R__fn_*), hier am Ende, weil sie transactions/account_balances lesen.
--   fn_recurring_last_done(rp): juengster erledigter (gebuchter ODER uebersprungener) Faelligkeitstermin der ganzen
--     Kette ("gebucht" keyt auf recurring_due_date). NULL = noch keiner.
--   fn_recurring_segments(rp): die AKTIVEN Glieder der Kette als Segment-Liste fuer fn_loan_balance_at
--     (Rhythmus, Gueltigkeit [valid_from, valid_to), Betrag positiv).
--   fn_loan_projected_balance(loan, target, today): voraussichtliche Restschuld zum Zieldatum (bei gleichem Zins, ohne
--     Sondertilgung) -- NULL bei pausiertem/abgeschlossenem Kredit, ohne Rate oder Ziel <= heute.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_last_done(p_rp_id int)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT max(x.d) FROM (
        SELECT max(t.recurring_due_date) AS d FROM finance.transactions t
         WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
        UNION ALL
        SELECT max(s.due_date) FROM finance.recurring_payment_skips s
         WHERE s.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
    ) x;
$$;

CREATE OR REPLACE FUNCTION finance.fn_recurring_segments(p_rp_id int)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_agg(jsonb_build_object(
               'anchor', r.first_payment_date, 'interval', r.schedule_interval, 'unit', r.schedule_unit,
               'dom', r.schedule_day_of_month, 'days', to_jsonb(r.schedule_days_of_month),
               'valid_from', r.valid_from, 'valid_to', r.valid_to, 'amount', abs(r.amount))
           ORDER BY r.valid_from)
    FROM finance.recurring_payments r
    WHERE r.id IN (SELECT finance.fn_recurring_lineage(p_rp_id)) AND r.status = 'active';
$$;

CREATE OR REPLACE FUNCTION finance.fn_loan_projected_balance(p_loan_id int, p_target date, p_today date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT finance.fn_loan_balance_at(
               GREATEST(-b.balance, 0), l.interest_rate,
               CASE WHEN l.status = 'active' THEN finance.fn_recurring_segments(l.recurring_payment_id) END,
               finance.fn_recurring_last_done(l.recurring_payment_id), p_target, p_today)
    FROM finance.loans l
    LEFT JOIN finance.account_balances b ON b.account_id = l.loan_account_id
    WHERE l.id = p_loan_id;
$$;

-- ============================================================
-- Reset-Lebenszyklus-Marker (Phase B, docs/package-contract.md §6 *Werkszustand-Reset*):
--   core.fn_reset_user_data leert JEDE Basistabelle dieses Schemas (deny-by-default) AUSSER den hier als
--   'lifecycle:reference' markierten Stammdaten (Muster PG pg_extension_config_dump: der Marker sitzt am
--   Objekt, faellt mit DROP SCHEMA). Eine NEUE Tabelle wird also automatisch zurueckgesetzt; eine neue
--   Stammdaten-/Cache-Tabelle MUSS hier markiert werden (tests/db/core/test_fn_reset_user_data.sql failt sonst).
-- ============================================================
COMMENT ON TABLE finance.currencies    IS 'lifecycle:reference - ISO-Waehrungs-Dimension (EUR-Seed + fn_ensure_currency), keine Nutzereingabe';
COMMENT ON TABLE finance.fx_rates      IS 'lifecycle:reference - FX-Kurs-Cache des Cron cron_refresh_fx_rates, keine Nutzereingabe';
COMMENT ON TABLE finance.market_prices IS 'lifecycle:reference - Marktpreis-Cache (Cron), keine Nutzereingabe';
