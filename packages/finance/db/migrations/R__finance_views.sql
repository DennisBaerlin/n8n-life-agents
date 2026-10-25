-- ============================================================
-- R__finance_views.sql — Flyway-REPEATABLE: alle Finance-Reporting-Views.
--
-- Repeatable (R__): laeuft bei JEDER Inhalts-Aenderung neu (Checksum-getrackt ueber
-- core.repeatable_should_apply). Laeuft NACH den Baseline-Inits UND den versionierten
-- V__-Migrationen (Treiber-Reihenfolge in db_apply.ps1 / apply_schema.sh) — d. h. die
-- Spalten-Endzustaende (z. B. finance_loans.disbursement_account_id nach V001) liegen
-- bereits vor. Die View-Helfer fn_to_eur/fn_monthly_equivalent sind INLINE-Baseline
-- (in den *_init.sql), nicht Tool-Repeatables -> existieren ebenfalls schon.
--
-- DROP VIEW IF EXISTS … CASCADE + CREATE VIEW (statt CREATE OR REPLACE): robust gegen
-- Output-Spalten-Renames/Umsortierung (CREATE OR REPLACE kann Output-Spalten weder
-- umbenennen noch droppen) -> KEINE information_schema-Drop-Guards mehr noetig.
-- Drop in UMGEKEHRTER, Create in normaler Dependency-Reihenfolge.
-- Inter-View-Deps: *_summary haengt an *_overview (loan_summary->loan_overview,
-- monthly_cashflow_summary->monthly_cashflow_overview); monthly_cashflow_overview und
-- parent_cashflow_overview haengen an recurring_cashflow_classified (EINE Klassifikation).
-- ============================================================

-- --- Drops (umgekehrte Dependency-Reihenfolge; CASCADE faengt evtl. Hand-Abhaengige) ---
DROP VIEW IF EXISTS finance.savings_goal_reserve_breakdown CASCADE;
DROP VIEW IF EXISTS finance.depot_reserve_status CASCADE;   -- haengt an depot_holdings_overview
DROP VIEW IF EXISTS finance.networth_by_asset_class CASCADE;
DROP VIEW IF EXISTS finance.loan_summary CASCADE;
DROP VIEW IF EXISTS finance.parent_cashflow_summary CASCADE;
DROP VIEW IF EXISTS finance.monthly_cashflow_summary CASCADE;   -- haengt (Paket 3) an cashflow_summary_by_scope
DROP VIEW IF EXISTS finance.cashflow_summary_by_scope CASCADE;
DROP VIEW IF EXISTS finance.parent_cashflow_overview CASCADE;
-- Defunct (Audit Paket 3): liquidity_net ist jetzt monthly_cashflow_summary.monthly_account_change.
-- Drop bleibt, damit bestehende DBs die Alt-View verlieren (idempotent).
DROP VIEW IF EXISTS finance.monthly_liquidity_summary CASCADE;
DROP VIEW IF EXISTS finance.depot_holdings_overview CASCADE;
DROP VIEW IF EXISTS finance.active_insurances CASCADE;
DROP VIEW IF EXISTS finance.pension_overview CASCADE;
DROP VIEW IF EXISTS finance.real_estate_overview CASCADE;
DROP VIEW IF EXISTS finance.savings_goal_progress CASCADE;
DROP VIEW IF EXISTS finance.account_reserve_status CASCADE;
DROP VIEW IF EXISTS finance.account_overview CASCADE;
DROP VIEW IF EXISTS finance.monthly_cashflow_overview CASCADE;
DROP VIEW IF EXISTS finance.recurring_cashflow_classified CASCADE;
DROP VIEW IF EXISTS finance.loan_overview CASCADE;
DROP VIEW IF EXISTS finance.active_recurring_payments CASCADE;
-- Defunct: finance_balance_drift_check (Policy lebt im cron_reconcile_accounts, nicht mehr
-- als View). Drop bleibt, damit bestehende DBs die Alt-View verlieren (idempotent).
DROP VIEW IF EXISTS finance.balance_drift_check CASCADE;

-- ============================================================
-- VIEW: Currently active recurring payments
-- Rohe Betriebssicht ALLER aktiven recurring payments (inkl. interner Transfers, target_account_id
-- gesetzt, amount Quell-seitig negativ). Fuer Cashflow-Aggregate NICHT diese View summieren -> die
-- transfer-bereinigten `monthly_cashflow_overview`/`_summary` nutzen (Doppelzaehl-Schutz, WS-2).
-- ============================================================
CREATE VIEW finance.active_recurring_payments AS
SELECT *,
       valid_to - 1 AS last_valid_day   -- valid_to ist exklusiv gespeichert ([valid_from, valid_to)); fuer den Nutzer das inklusive Ende
FROM finance.recurring_payments
WHERE status = 'active'
  AND valid_from <= current_date
  AND (valid_to IS NULL OR valid_to > current_date);

-- ============================================================
-- VIEW: Loan overview with current Restschuld
-- Joins loans with their live balance so the LLM gets all
-- relevant loan data including outstanding debt in one query.
-- EINE QUELLE (WP2, finance:V026): Rate und Abbuchungstag kommen aus dem HEUTE gueltigen Glied der Raten-Kette
-- (fn_recurring_current) -- die Kredit-Zeile traegt keine Kopie mehr. Abgeleitet (nie gespeichert):
--   initial_principal_rate           = rechnerische anfaengliche Tilgung in % p.a. aus Kreditbetrag + ERSTER erfasster
--                                      Rate (aeltestes Glied, Jahreswert ueber fn_annual_equivalent) - Zins; nur mit
--                                      original_amount und Rate.
--   balance_at_*_projected           = voraussichtliche Restschuld zum Zinsbindungs- bzw. Laufzeitende (bei gleichem
--                                      Zins, ohne Sondertilgung; fn_loan_projected_balance; NULL wenn pausiert, ohne
--                                      Rate oder Datum <= heute).
-- ============================================================
CREATE VIEW finance.loan_overview AS
SELECT
    l.id,
    l.name,
    l.lender,
    -- WS-4: Freitext-borrower abgeloest -> abgeleitete Eigentuemer-Anzeige aus dem typisierten FK
    -- (core.fn_household_persons-Fenster; NULL=Haushalt). Output-Spaltenname bleibt borrower (Consumer-stabil).
    COALESCE(bp.full_name, 'Haushalt')  AS borrower,
    l.borrower_person_id,
    l.original_amount,
    l.disbursement_date,
    l.interest_rate,
    l.interest_rate_fixed_until,
    abs(rc.amount)                     AS monthly_annuity,   -- Rate des heute gueltigen Glieds (Spaltenname consumer-stabil)
    l.status,
    b.balance                          AS current_remaining_debt,
    l.loan_account_id,
    l.debit_account_id,
    l.notes,
    l.disbursement_account_id,
    -- Zins/Tilgung dynamisch aus der LIVE-Restschuld (nicht origination): exakt fuer laufende Kredite.
    -- Zinsanteil = aktuelle Restschuld x Zinssatz / 12; Tilgungsanteil = gegebene Rate - Zinsanteil.
    -- Audit Paket 3: die EINE Zinsformel fn_loan_monthly_interest (wie Cashflow-Klassifikation + Raten-Vorschau)
    finance.fn_loan_monthly_interest(-b.balance, l.interest_rate) AS monthly_interest_current,
    abs(rc.amount) - finance.fn_loan_monthly_interest(-b.balance, l.interest_rate) AS monthly_principal_current,
    -- Multi-Waehrung: Loan-Konto-Waehrung + Restschuld in EUR-Basis.
    la.currency,
    finance.fn_to_eur(b.balance, la.currency) AS current_remaining_debt_eur,
    -- WP2 (Spalten am Ende):
    l.term_end_date,
    rc.schedule_day_of_month,
    l.recurring_payment_id,
    CASE WHEN l.original_amount > 0 AND fr.amount IS NOT NULL THEN
        ROUND(finance.fn_annual_equivalent(abs(fr.amount), fr.schedule_interval, fr.schedule_unit,
                                           COALESCE(cardinality(fr.schedule_days_of_month), 1))
              / l.original_amount * 100 - l.interest_rate, 2)
    END                                AS initial_principal_rate,
    finance.fn_loan_projected_balance(l.id, l.interest_rate_fixed_until, current_date) AS balance_at_fixed_until_projected,
    finance.fn_loan_projected_balance(l.id, l.term_end_date, current_date)             AS balance_at_term_end_projected
FROM finance.loans l
LEFT JOIN finance.recurring_payments rc ON rc.id = finance.fn_recurring_current(l.recurring_payment_id, current_date)
LEFT JOIN LATERAL (
    SELECT r.amount, r.schedule_interval, r.schedule_unit, r.schedule_days_of_month
    FROM finance.recurring_payments r
    WHERE r.id IN (SELECT finance.fn_recurring_lineage(l.recurring_payment_id))
    ORDER BY r.valid_from, r.id LIMIT 1) fr ON true
LEFT JOIN finance.account_balances b ON b.account_id = l.loan_account_id
LEFT JOIN finance.accounts la ON la.id = l.loan_account_id
LEFT JOIN core.fn_household_persons() bp ON bp.person_id = l.borrower_person_id;

-- ============================================================
-- VIEW: Cashflow-Klassifikation (Audit Paket 3) — die EINE Quelle fuer Konsum / Tilgung / Sparen
-- Je LAUFENDER recurring payment (Praedikat wie active_recurring_payments) die Klasse + die EUR-Anteile.
-- Gelesen von monthly_cashflow_overview (Familie) und parent_cashflow_overview (Eltern-Blick) -> beide
-- Sichten klassifizieren identisch (keine zweite Definition). Reihenfolge (keine Exklusivitaet ueber
-- Tabellen hinweg, daher feste CASE-Prioritaet):
--   income          monthly_equivalent > 0 (auch eine Vorsorge-AUSZAHLUNG)
--   loan            Kredit-rp (loans.recurring_payment_id): Zins = Konsum, Rest = Tilgung. Zins aus
--                   fn_loan_monthly_interest (dieselbe Formel wie die Kreditraten-Vorschau), in der
--                   Kreditkonto-Waehrung, gedeckelt auf die Rate (Tilgung nie positiv). Fehlt der FX-Kurs
--                   der Kreditwaehrung -> ganze Rate Konsum + fx_gap (nie still verschwinden).
--   saving          negative rp eines Sparplans / Sparziels / Vorsorge-Vertrags (Vermoegensaufbau, ruhend
--                   stellbar -> keine Pflichtausgabe). Sparziel-Raten MIT Topf (target_account_id) zaehlen
--                   hier als Sparen, obwohl sie ein interner Transfer sind.
--   saving_internal Spar-rp auf einem Konto, dessen Spar-Abfluss vollstaendig von laufenden Spar-Ueberweisungen
--                   gegenfinanziert ist (Sparziel-Topf = Verrechnungskonto des Sparplans; Eltern->Kind-Ziel +
--                   Kind-Sparplan) -> 0: das Geld galt beim Verlassen des Girokontos schon als gespart. Bei
--                   teilweiser Deckung bleibt die Klasse saving, nur der gegenfinanzierte Anteil faellt heraus.
--   transfer        sonstiger interner Transfer own<->own (cashflow-neutral, WS-2; BACKLOG "Cash-Runway ueber
--                   ALLE Transfers" bewusst YAGNI) -> 0
--   consumption     alles Uebrige
-- Geld-Spalten in EUR, Vorzeichen roh (Ausgaben <= 0): income_eur, consumption_eur, principal_eur, saving_eur.
-- fx_gap = ein Betrag != 0 ohne EUR-Kurs (Zeile oder Kreditwaehrung) -> Summen melden es als has_fx_gap.
-- ============================================================
CREATE VIEW finance.recurring_cashflow_classified AS
WITH base AS (
    SELECT rp.*,
           a.name                                           AS account_name,
           a.currency,
           a.owner_person_id                                AS account_owner_person_id,
           finance.fn_to_eur(rp.monthly_equivalent, a.currency) AS monthly_equivalent_eur,
           ln.loan_id,
           ln.loan_interest_eur,
           ln.loan_interest_native,
           -- Besitzer zeigen immer auf den KOPF der Vorgaenger-Kette (Paket 2) -> eine alte, noch laufende Zeile eines
           -- in die Zukunft geaenderten Sparplans/Kredits bleibt so Sparen/Kredit statt Konsum.
           EXISTS (SELECT 1 FROM finance.savings_plans sp WHERE sp.recurring_payment_id = h.head)
           OR EXISTS (SELECT 1 FROM finance.savings_goals g WHERE g.recurring_payment_id = h.head)
           OR EXISTS (SELECT 1 FROM finance.pension p WHERE p.recurring_payment_id = h.head) AS is_saving_link
    FROM finance.recurring_payments rp
    JOIN finance.accounts a ON a.id = rp.account_id
    CROSS JOIN LATERAL (SELECT COALESCE(finance.fn_recurring_lineage_head(rp.id), rp.id) AS head) h
    LEFT JOIN LATERAL (
        SELECT l.id AS loan_id,
               finance.fn_loan_monthly_interest(-lb.balance, l.interest_rate)                    AS loan_interest_native,
               finance.fn_to_eur(finance.fn_loan_monthly_interest(-lb.balance, l.interest_rate), la.currency) AS loan_interest_eur
        FROM finance.loans l
        JOIN finance.accounts la ON la.id = l.loan_account_id
        LEFT JOIN finance.account_balances lb ON lb.account_id = l.loan_account_id
        WHERE l.recurring_payment_id = h.head
        ORDER BY l.id
        LIMIT 1
    ) ln ON true
    WHERE rp.status = 'active'
      AND rp.valid_from <= current_date
      AND (rp.valid_to IS NULL OR rp.valid_to > current_date)
),
-- Spar-Zufluss je Konto (laufende Spar-Ueberweisungen in dieses Konto) vs. Spar-Abfluss von diesem Konto: der
-- gegenfinanzierte ANTEIL der dortigen Spar-Raten (LEAST(Zufluss/Abfluss, 1)) zaehlt nicht erneut als Sparen.
-- Anteilig, nicht die ganze Rate: Topf bekommt 50 Ziel-Rate, Sparplan bucht 500 ab -> 450 bleiben echtes Sparen.
saving_in AS (
    SELECT target_account_id AS acct, sum(-monthly_equivalent_eur) AS amt
    FROM base WHERE target_account_id IS NOT NULL AND is_saving_link AND loan_id IS NULL AND monthly_equivalent < 0
    GROUP BY target_account_id
),
saving_out AS (
    SELECT account_id AS acct, sum(-monthly_equivalent_eur) AS amt
    FROM base WHERE is_saving_link AND loan_id IS NULL AND monthly_equivalent < 0
    GROUP BY account_id
),
classed AS (
    SELECT b.*,
           -- LEAST ignoriert NULL (LEAST(NULL,1)=1) -> erst COALESCE, dann deckeln
           LEAST(COALESCE(si.amt / NULLIF(so.amt, 0), 0), 1) AS internal_share,
           CASE
               WHEN b.monthly_equivalent > 0 THEN 'income'
               WHEN b.loan_id IS NOT NULL THEN 'loan'
               WHEN b.is_saving_link AND b.monthly_equivalent < 0 THEN
                   CASE WHEN COALESCE(si.amt / NULLIF(so.amt, 0), 0) >= 1 THEN 'saving_internal' ELSE 'saving' END
               WHEN b.target_account_id IS NOT NULL THEN 'transfer'
               ELSE 'consumption'
           END AS cashflow_class,
           -- Konsum-Anteil einer Kreditrate: Zins (<= Rate); ohne Zins-EUR (FX fehlt) die ganze Rate
           CASE WHEN b.loan_interest_eur IS NULL THEN b.monthly_equivalent_eur
                ELSE GREATEST(b.monthly_equivalent_eur, -b.loan_interest_eur) END AS loan_consumption_eur
    FROM base b
    LEFT JOIN saving_in  si ON si.acct = b.account_id
    LEFT JOIN saving_out so ON so.acct = b.account_id
)
SELECT c.id,
       c.name,
       c.amount,
       c.schedule_interval,
       c.schedule_unit,
       c.schedule_days_of_month,   -- feste Monatstage (z. B. Broker-Kalender): "month, interval 1" heisst dann 4x/Monat
       c.monthly_equivalent,
       c.account_id,
       c.account_name,
       c.target_account_id,
       c.account_owner_person_id,
       c.status,
       c.valid_from,
       c.valid_to,
       c.currency,
       c.monthly_equivalent_eur,
       c.valid_to - 1 AS last_valid_day,   -- inklusives Ende fuer den Nutzer (valid_to ist exklusiv gespeichert)
       c.cashflow_class,
       CASE WHEN c.cashflow_class = 'income' THEN c.monthly_equivalent_eur ELSE 0 END          AS income_eur,
       CASE c.cashflow_class WHEN 'consumption' THEN c.monthly_equivalent_eur
                             WHEN 'loan'        THEN c.loan_consumption_eur ELSE 0 END      AS consumption_eur,
       CASE WHEN c.cashflow_class = 'loan'
            THEN c.monthly_equivalent_eur - c.loan_consumption_eur ELSE 0 END               AS principal_eur,
       CASE WHEN c.cashflow_class = 'saving'
            THEN round(c.monthly_equivalent_eur * (1 - c.internal_share), 2) ELSE 0 END    AS saving_eur,
       ((c.monthly_equivalent <> 0 AND c.monthly_equivalent_eur IS NULL)
        OR (c.cashflow_class = 'loan' AND c.loan_interest_native > 0 AND c.loan_interest_eur IS NULL)) AS fx_gap
FROM classed c;

-- ============================================================
-- VIEW: Active recurring payments normalized to monthly amounts (Familie)
-- Filters to currently active payments (date + status) so
-- the LLM can read the full cashflow picture without WHERE clauses.
-- WS-2 (Multi-Member): INTERNE Transfers own<->own sind ausgeschlossen (cashflow_class='transfer'), damit
-- eine Bewegung zwischen eigenen Konten nicht als Haushalts-Ein-/Ausgabe doppelzaehlt (Standard Actual/YNAB).
-- Audit Paket 3: Sparziel-Raten in einen Topf stehen als cashflow_class='saving' DRIN; Klasse + EUR-Anteile
-- (income/consumption/principal/saving) kommen aus recurring_cashflow_classified.
-- ============================================================
CREATE VIEW finance.monthly_cashflow_overview AS
SELECT id, name, amount, schedule_interval, schedule_unit, schedule_days_of_month, monthly_equivalent, account_id, account_name,
       status, valid_from, valid_to, currency, monthly_equivalent_eur, last_valid_day,
       target_account_id, cashflow_class, income_eur, consumption_eur, principal_eur, saving_eur, fx_gap
FROM finance.recurring_cashflow_classified
WHERE cashflow_class <> 'transfer';

-- ============================================================
-- VIEW: Account overview with live balance
-- Base view for almost every account-related LLM query:
-- joins accounts with their auto-maintained balance.
-- ============================================================
CREATE VIEW finance.account_overview AS
SELECT
    a.id,
    a.name,
    a.account_type,
    a.bank,
    a.account_number,
    -- WS-4: Freitext-account_holder abgeloest -> abgeleitete Eigentuemer-Anzeige aus dem typisierten FK
    -- (core.fn_household_persons-Fenster; NULL=Haushalt). Output-Spaltenname bleibt account_holder (Consumer-stabil).
    COALESCE(ap.full_name, 'Haushalt')  AS account_holder,
    a.owner_person_id,
    a.currency,
    a.status,
    a.settlement_account_id,
    a.fixed_deposit_maturity_date,
    a.fixed_deposit_auto_renew,
    b.balance,
    b.updated_at  AS balance_updated_at,
    a.notes,
    -- Multi-Waehrung (ans Ende angehaengt): Saldo in EUR-Basis fuer Roll-ups/Net-Worth.
    finance.fn_to_eur(b.balance, a.currency) AS balance_eur
FROM finance.accounts a
LEFT JOIN finance.account_balances b ON b.account_id = a.id
LEFT JOIN core.fn_household_persons() ap ON ap.person_id = a.owner_person_id;

-- ============================================================
-- VIEW: Savings goal progress  (WS-A Phase S: RESERVE-Modell, Ziel-Tag-Envelope)
-- current_amount = aktuelle RESERVE des Ziels = vorzeichen-rohe Summe ALLER mit dem Ziel markierten
-- Buchungen (transactions.savings_goal_id) — ueber BELIEBIG viele Konten (Tagesgeld + Depot). Reserve-
-- Zufluss (Sparrate-Haben-Bein, Einmal-Summe) zaehlt +, Entnahme/Reserve-Abfluss zaehlt - => eine Entnahme
-- SENKT den Fortschritt automatisch (Owner-Fall "Erspartes anderweitig gebraucht"). Etablierter Standard
-- (YNAB/Actual-Umschlag, Firefly-Piggy): Fortschritt = aktueller Topf-STAND, nicht die Summe der Einzahlungen.
--   * Nur das RESERVE-Bein wird getaggt (das Haben-Bein der Rate-Umbuchung; nie beide Beine -> sonst Netto-0).
--     Die Stempelung macht fn_book_recurring_transfer (Rate eines Ziels); Entnahme/Einmal tragen das Tag direkt.
--   * Kein Tag UND kein Journal -> current_amount 0 (Defensiv-Zweig; ein Ziel ohne Reserve-Bewegung hat 0).
--   * WS-B: Depot-Reserve-Term = signed SUM(savings_goal_reserve_entries.delta_native (je Zeile via fn_to_eur nach EUR)) je Ziel (append-only
--     Journal, DERIVED -> driftfrei), ADDITIV zum Cash-Term (current_amount = saved = Cash + Depot-Journal).
--     Der Depot-MARKTWERT ist NUR Deckung (depot_reserve_status), NIE der gespeicherte Reserve-Stand.
--   * RETIRED (finance:V008): savings_goal_holdings (Marktwert-Term, doppelzaehl-anfaellig) + savings_goal_
--     allocations (Earmark/FIRE); das FIRE-Topf-Netting ist nach BACKLOG verschoben (Fundament zuerst).
-- Erkenntnis-Fakten (DB rechnet, LLM reasoned darueber): expected_percent (Zeit-Pace), pace_drift_pp,
--   observed_monthly_rate, projected_completion_date (beim beobachteten Tempo), required_catchup_rate
--   (um das Zieldatum zu halten). Anker durchgaengig created_at; Div/0 + Vorzeichen geguardet
--   (projected/catchup = NULL bei gedecktem Ziel bzw. Zieldatum nicht in der Zukunft). Toleranz-Schwelle
--   bewusst NICHT hier — der Advisor wendet drift_pace_pp an.
-- Multi-Member (WS-3b): traegt beneficiary_person_id (beguenstigte Person je Ziel; NULL = Haushalt) ->
--   Pro-Kind-Ziel-Fortschritt; Fortschritt haengt am Ziel-rp, NICHT am finanzierenden Konto (orthogonal).
-- Output-Spaltennamen current_amount/progress_percent sind consumer-stabil (fn_advisor_review liest sie namentlich).
-- ============================================================
CREATE VIEW finance.savings_goal_progress AS
WITH contrib AS (
    -- WP-3b: Cash-Term je Konto-Waehrung nach EUR (fn_to_eur mit dem transaction_date-Kurs) — eine Reserve, die
    -- auf Konten VERSCHIEDENER Waehrungen getaggt ist, wuerde sonst roh gemischt (still falsch). Der Depot-Term
    -- (reserve-CTE) konvertiert mit DERSELBEN Live-Semantik -> die goal-Kauf-Legs kuerzen sich exakt (Konservierung).
    SELECT t.savings_goal_id                             AS goal_id,
           sum(finance.fn_to_eur(t.amount, a.currency, t.transaction_date)) AS booked   -- vorzeichen-roh: Zufluss +, Entnahme -
    FROM finance.transactions t
    JOIN finance.accounts a ON a.id = t.account_id
    WHERE t.savings_goal_id IS NOT NULL
    GROUP BY t.savings_goal_id
),
-- WS-B/WP-3b: Depot-Anteil der Reserve = signed SUM(fn_to_eur(delta_native, currency, value_date)) je Ziel — ein
-- APPEND-ONLY Journal (nativer Betrag je Zeile, EUR-Umrechnung live in der VIEW; DERIVED -> kann strukturell nicht
-- driften). ADDITIV zum Cash-Term. Der MARKTWERT eines Depots ist NUR Deckel/Deckung (depot_reserve_status), NIE der Fortschritt ->
-- eine Kurs-Explosion blaeht current_amount nicht auf (Owner-Einwand; das fruehere savings_goal_holdings-
-- Marktwert-Modell ist mit finance:V008 RETIRED, weil es bei geteiltem/vorbestehendem ISIN doppelzaehlte).
-- COALESCE(depot_reserve,0): kein Journal -> 0 (defensiv, kein Kippen der Summe auf NULL).
reserve AS (
    -- WP-3b: jede Journal-Zeile traegt einen NATIVEN Betrag + ihre Waehrung + value_date -> nach EUR via fn_to_eur
    -- (Live-Semantik wie der Cash-Term). sparplan_buy = Depot-Waehrung, manual = EUR.
    SELECT savings_goal_id AS goal_id,
           sum(finance.fn_to_eur(delta_native, currency, value_date)) AS depot_reserve
    FROM finance.savings_goal_reserve_entries
    GROUP BY savings_goal_id
),
-- saved = aktueller Reserve-Stand = Cash-Tag-Term + Depot-Journal-Term. EINE Quelle fuer ALLE Erkenntnis-
-- Fakten unten (sonst driften current_amount und progress/pace auseinander).
-- Audit Paket 3: measurable = FALSE genau dann, wenn die Raten-rp des Ziels GERADE LAEUFT (Praedikat wie
-- active_recurring_payments) und KEINEN Topf hat (target_account_id NULL): die Rate geht dann als nackte
-- Abbuchung unverfolgt vom Konto ab -> Fortschritt/Tempo sind nicht messbar (statt Dauer-"hinter Plan").
-- Beendete/pausierte Raten + einmalige getaggte Einzahlungen bzw. Journal-Eintraege bleiben messbar.
base AS (
    SELECT g.*,
           coalesce(c.booked, 0) + coalesce(r.depot_reserve, 0) AS saved,
           -- ueber die ganze Vorgaenger-Kette (Paket 2): eine alte, noch laufende Zeile ohne Topf zaehlt mit, auch wenn
           -- der Kopf (auf den das Ziel zeigt) erst spaeter gilt.
           NOT EXISTS (SELECT 1
                       FROM finance.fn_recurring_lineage(g.recurring_payment_id) lid
                       JOIN finance.recurring_payments rp ON rp.id = lid
                       WHERE rp.status = 'active'
                         AND rp.valid_from <= current_date
                         AND (rp.valid_to IS NULL OR rp.valid_to > current_date)
                         AND rp.target_account_id IS NULL) AS measurable
    FROM finance.savings_goals g
    LEFT JOIN contrib c ON c.goal_id = g.id
    LEFT JOIN reserve r ON r.goal_id = g.id
)
SELECT
    b.id,
    b.name,
    b.goal_type,
    b.target_amount,
    b.target_date,
    b.saved                                             AS current_amount,
    b.target_amount - b.saved                           AS remaining_amount,
    CASE
        WHEN b.target_amount > 0 AND b.measurable
        THEN round(b.saved / b.target_amount * 100, 2)
        ELSE NULL
    END                                                 AS progress_percent,
    (b.target_date - current_date)                      AS days_remaining,
    -- erwarteter Zeit-Pace (elapsed/total seit created_at); NULL wenn Zieldatum nicht nach created_at
    CASE WHEN b.target_date > b.created_at::date
         THEN round(LEAST(GREATEST((current_date - b.created_at::date)::numeric
                                   / (b.target_date - b.created_at::date), 0), 1) * 100, 2)
         ELSE NULL END                                  AS expected_percent,
    -- pace_drift_pp = erwartet - tatsaechlich (positiv = hinter Plan); NULL wenn nicht messbar
    CASE WHEN b.target_date > b.created_at::date AND b.target_amount > 0 AND b.measurable
         THEN round(LEAST(GREATEST((current_date - b.created_at::date)::numeric
                                   / (b.target_date - b.created_at::date), 0), 1) * 100
                    - b.saved / b.target_amount * 100, 2)
         ELSE NULL END                                  AS pace_drift_pp,
    -- beobachtetes Monatstempo = bisher gespart / vergangene Monate (GREATEST(1,..)-Guard). NULL bei saved<=0:
    -- im Reserve-Modell kann eine Netto-Entnahme saved unter 0 druecken -> ein NEGATIVES "Spartempo" waere
    -- semantisch falsch (der Advisor liest die Spalte) -> wie projected_completion_date auf saved>0 geguardet.
    CASE WHEN b.saved > 0 AND b.measurable
         THEN round(b.saved
              / GREATEST(1, ceil((current_date - b.created_at::date)::numeric / finance.fn_days_per_month())), 2)
         ELSE NULL END                                  AS observed_monthly_rate,
    -- voraussichtliches Erreichungs-Datum beim beobachteten Tempo; NULL wenn Tempo 0 ODER bereits gedeckt
    CASE WHEN b.saved > 0 AND b.target_amount - b.saved > 0 AND b.measurable
         THEN (current_date + (round(
                 (b.target_amount - b.saved)
                 / (b.saved
                    / GREATEST(1, ceil((current_date - b.created_at::date)::numeric / finance.fn_days_per_month())))
                 * finance.fn_days_per_month())::int) * interval '1 day')::date
         ELSE NULL END                                  AS projected_completion_date,
    -- noetige Nachhol-Rate, um das Zieldatum zu halten; NULL wenn Zieldatum nicht in der Zukunft ODER gedeckt
    CASE WHEN b.target_date > current_date AND b.target_amount - b.saved > 0 AND b.measurable
         THEN round((b.target_amount - b.saved)
                    / GREATEST(1, ceil((b.target_date - current_date)::numeric / finance.fn_days_per_month())), 2)
         ELSE NULL END                                  AS required_catchup_rate,
    b.recurring_payment_id,
    b.beneficiary_person_id,
    b.priority,                                          -- WS-C1: Engpass-Reihung (kleiner = wichtiger; NULL = unpriorisiert)
    b.status,
    b.notes,
    b.measurable                                        AS progress_measurable   -- Audit Paket 3 (ans Ende angehaengt)
FROM base b;

-- ============================================================
-- VIEW: Account reserve status  (WS-C2 Phase S — proaktiver Reserve-Waechter)
-- Pro AKTIVEM Konto: live-Saldo vs. der darauf fuer aktive Sparziele RESERVIERTE Betrag.
--   reserved = SUM(transactions.amount WHERE savings_goal_id) ueber AKTIVE Ziele (Join status='active'),
--     in der NATIVE-Waehrung des Kontos (alle Tx eines Kontos teilen dessen Waehrung -> Saldo vs. reserviert
--     ist apfel-zu-apfel, KEIN FX). Quelle ist DIESELBE Tag-Summe wie savings_goal_progress, nur per-Konto
--     statt per-Ziel gruppiert.
--   breach = reserved>0 AND balance<reserved -> der Saldo deckt die zurueckgelegte Reserve nicht mehr
--     (der Owner hat „in seinen Sparbetrag eingegriffen"). Etablierter Standard: YNAB „Warn when target balance
--     not reached", Firefly „account balance >= sum of piggy allocations" — bei uns ADVISORY (nie blockierend).
--   shortfall = GREATEST(reserved-balance, 0) (nie NULL; balance/reserved COALESCEt).
-- WICHTIG (Tag-Envelope, per-KONTO nicht per-Ziel): der Konto-Saldo poolt alle Earmarks -> „aus welchem Ziel
--   kam dieser Euro?" ist keine reale Tatsache; das ist eine Konto-LIQUIDITAETS-Sicht. Per-Ziel-Drill-down
--   beantwortet der Agent on demand aus savings_goal_progress.
-- Ein completed/cancelled-Ziel faellt aus dem status='active'-Join -> es GIBT SEINE RESERVE FREI -> ein Konto
--   kann dadurch ent-breachen (kein Bug). Ein hart-geloeschtes Ziel: savings_goal_id ON DELETE SET NULL -> der
--   Tag faellt automatisch raus.
-- Konsumenten: fn_reserve_breach (per-Konto-Read fuer den Buch-fn-Fold), fn_advisor_review (reserve_coverage),
--   finance_ro (Drill-down) — Lesezugriff aus dem schema-weiten GRANT (wie alle Views, kein per-View-GRANT).
-- ============================================================
CREATE VIEW finance.account_reserve_status AS
SELECT a.id                                             AS account_id,
       a.name                                           AS account_name,
       a.currency,
       COALESCE(b.balance, 0)                           AS balance,
       COALESCE(r.reserved, 0)                          AS reserved,
       GREATEST(COALESCE(r.reserved, 0) - COALESCE(b.balance, 0), 0) AS shortfall,
       (COALESCE(r.reserved, 0) > 0 AND COALESCE(b.balance, 0) < COALESCE(r.reserved, 0)) AS breach
FROM finance.accounts a
LEFT JOIN finance.account_balances b ON b.account_id = a.id
LEFT JOIN (
    SELECT t.account_id, sum(t.amount) AS reserved        -- getaggte Tx je Konto, nur aktive Ziele
    FROM finance.transactions t
    JOIN finance.savings_goals g ON g.id = t.savings_goal_id
    WHERE g.status = 'active'
    GROUP BY t.account_id
) r ON r.account_id = a.id
WHERE a.status = 'active';

-- ============================================================
-- VIEW: Real estate overview with associated debt and net equity
-- Joins properties with their OUTSTANDING loans (via real_estate_id; active ODER paused =
-- finance.fn_loan_is_outstanding, Audit Paket 2 -- vorher nur active, ein pausierter Kredit fehlte im Eigenkapital)
-- and the loan accounts' current Restschuld (negative balance).
-- net_equity = current_value + associated_debt (debt is negative). active_loan_count zaehlt nur aktive.
-- has_fx_gap (am Ende): eine Restschuld in Fremdwaehrung ohne Kurs fiele sonst still als 0 aus der Summe.
-- ============================================================
CREATE VIEW finance.real_estate_overview AS
SELECT
    re.id,
    re.name,
    re.current_value,
    re.value_updated_at,
    -- WS-4: Freitext-owner abgeloest -> abgeleitete Eigentuemer-Anzeige (NULL=Haushalt); Name bleibt owner.
    COALESCE(rep.full_name, 'Haushalt')  AS owner,
    re.owner_person_id,
    re.status,
    -- Multi-Waehrung: Restschuld in EUR konvertieren (Loan-Konto-Waehrung); current_value gilt als EUR.
    coalesce(sum(finance.fn_to_eur(b.balance, ka.currency)), 0)                AS associated_debt,    -- negative, EUR
    re.current_value + coalesce(sum(finance.fn_to_eur(b.balance, ka.currency)), 0) AS net_equity,
    count(l.id) FILTER (WHERE l.status = 'active')      AS active_loan_count,
    re.notes,
    COALESCE(bool_or(b.balance <> 0 AND finance.fn_to_eur(b.balance, ka.currency) IS NULL), false) AS has_fx_gap
FROM finance.real_estate re
LEFT JOIN finance.loans l
    ON l.real_estate_id = re.id AND finance.fn_loan_is_outstanding(l.status)
LEFT JOIN finance.account_balances b
    ON b.account_id = l.loan_account_id
LEFT JOIN finance.accounts ka
    ON ka.id = l.loan_account_id
LEFT JOIN core.fn_household_persons() rep ON rep.person_id = re.owner_person_id
GROUP BY re.id, re.name, re.current_value, re.value_updated_at,
         rep.full_name, re.owner_person_id, re.status, re.notes;

-- ============================================================
-- VIEW: Pension overview (net-worth building block)
-- One row per pension provision + the linked Beitrag (recurring_payment) if any.
-- current_value may be NULL (e.g. statutory) -> excluded from net-worth sums by callers.
-- WP2: Beitrag je Abbuchung + Rhythmus kommen aus dem heute gueltigen Glied der Beitrags-Kette; monthly_contribution
-- ist der daraus abgeleitete Monatswert (rp.monthly_equivalent; vorher roh rp.amount -> bei jaehrlichem Beitrag falsch).
-- ============================================================
CREATE VIEW finance.pension_overview AS
SELECT
    p.id,
    p.name,
    p.pension_type,
    p.provider,
    p.contract_number,
    -- WS-4: Freitext-owner abgeloest -> abgeleitete Eigentuemer-Anzeige (NULL=Haushalt); Name bleibt owner.
    COALESCE(pp.full_name, 'Haushalt')                 AS owner,
    p.owner_person_id,
    p.current_value,
    p.value_updated_at,
    p.guaranteed_monthly_pension,
    p.retirement_start_date,
    rc.monthly_equivalent                              AS monthly_contribution,  -- negative (expense) or NULL, Monatswert
    p.recurring_payment_id,
    p.status,
    p.notes,
    abs(rc.amount)                                     AS contribution_amount,   -- WP2: Beitrag je Abbuchung
    rc.schedule_interval,
    rc.schedule_unit
FROM finance.pension p
LEFT JOIN finance.recurring_payments rc ON rc.id = finance.fn_recurring_current(p.recurring_payment_id, current_date)
LEFT JOIN core.fn_household_persons() pp ON pp.person_id = p.owner_person_id;

-- ============================================================
-- VIEW: Currently active insurances (mirrors finance_active_recurring_payments)
-- Filters to active + date-valid insurances and joins the debit account name.
-- EINE QUELLE (WP2, finance:V027): Beitrag je Abbuchung, Rhythmus, Tag und Konto aus dem heute gueltigen Glied der
-- Beitrags-Kette, das Vertragsende (valid_to, exklusiv) vom Kopf der Kette. annual_premium/monthly_equivalent sind
-- ABGELEITET (fn_annual_equivalent bzw. rp.monthly_equivalent; Spaltennamen consumer-stabil, positiv). Ohne
-- Beitrags-Kette (beitragsfreie Police) sind die Beitrags-Spalten NULL.
-- ============================================================
CREATE VIEW finance.active_insurances AS
SELECT
    i.id,
    i.name,
    i.insurance_company,
    i.policy_number,
    -- WS-4: Freitext-policyholder abgeloest -> abgeleitete Anzeige (NULL=Haushalt); Name bleibt policyholder.
    COALESCE(ip.full_name, 'Haushalt')  AS policyholder,
    i.policyholder_person_id,
    finance.fn_annual_equivalent(abs(rc.amount), rc.schedule_interval, rc.schedule_unit,
                                 COALESCE(cardinality(rc.schedule_days_of_month), 1)) AS annual_premium,
    -rc.monthly_equivalent              AS monthly_equivalent,
    rc.schedule_interval,
    rc.schedule_unit,
    rc.schedule_day_of_month,
    i.valid_from,
    hd.valid_to,
    rc.account_id,
    a.name  AS account_name,
    i.notes,
    abs(rc.amount)                      AS premium_amount,      -- WP2 (am Ende): Beitrag je Abbuchung
    i.recurring_payment_id
FROM finance.insurances i
LEFT JOIN finance.recurring_payments rc ON rc.id = finance.fn_recurring_current(i.recurring_payment_id, current_date)
LEFT JOIN finance.recurring_payments hd ON hd.id = i.recurring_payment_id
LEFT JOIN finance.accounts a ON a.id = rc.account_id
LEFT JOIN core.fn_household_persons() ip ON ip.person_id = i.policyholder_person_id
WHERE i.status = 'active'
  AND i.valid_from <= current_date
  AND (hd.valid_to IS NULL OR hd.valid_to > current_date);

-- ============================================================
-- VIEW: Depot holdings with account name, book value AND live market value (Phase M)
-- book_value      = shares * average_purchase_price (Gewinn-Basis, immer gefuellt).
-- market_value    = shares * juengster market_prices.price (NULL wenn KEIN Live-Kurs vorliegt -> ehrlich
--                   "noch kein Kurs" statt Buchwert-Fallback; der COALESCE-Fallback gilt nur im Summen-
--                   Roll-up networth_by_asset_class, NIE in dieser Anzeige-View, sonst suggeriert
--                   unrealized_gain_eur=0 faelschlich "kein Gewinn"). price_as_of=NULL = derselbe Zustand.
-- Die Kurs-Waehrung ist die im market_prices gespeicherte (= COALESCE(quote_currency, currency), Phase M) ->
-- die EUR-Konvertierung nimmt lp.price_currency, der Buchwert h.currency.
-- ============================================================
CREATE VIEW finance.depot_holdings_overview AS
WITH latest_price AS (
    SELECT DISTINCT ON (mp.symbol) mp.symbol, mp.price, mp.currency AS price_currency, mp.as_of
    FROM finance.market_prices mp
    ORDER BY mp.symbol, mp.as_of DESC
)
SELECT
    h.id,
    h.account_id,
    a.name                                              AS account_name,
    a.account_type,
    h.isin,
    h.symbol,
    h.name,
    h.shares,
    h.average_purchase_price,
    round(h.shares * h.average_purchase_price, 2)       AS book_value,
    h.currency,
    h.updated_at,
    -- Multi-Waehrung (ans Ende angehaengt): Buchwert in EUR-Basis fuer Portfolio-Roll-ups.
    finance.fn_to_eur(round(h.shares * h.average_purchase_price, 2), h.currency) AS book_value_eur,
    -- Phase M Live-Marktwert (NULL wenn kein Kurs): market_value nativ in lp.price_currency, _eur konvertiert,
    -- price_as_of als Kurs-Datum, unrealized_gain_eur = Marktwert_eur - Buchwert_eur (alle NULL ohne Kurs).
    lp.as_of                                            AS price_as_of,
    round(h.shares * lp.price, 2)                       AS market_value,
    finance.fn_to_eur(round(h.shares * lp.price, 2), lp.price_currency)          AS market_value_eur,
    finance.fn_to_eur(round(h.shares * lp.price, 2), lp.price_currency)
        - finance.fn_to_eur(round(h.shares * h.average_purchase_price, 2), h.currency) AS unrealized_gain_eur,
    -- Monats-Check WP-G: die Tool-Descriptions (sell/set/delete holding) sprechen von "holding_id from
    -- depot_holdings_overview"; der Agent fragte die Spalte so ab und lief auf einen Fehler (2026-10-22).
    h.id                                                AS holding_id,
    -- 2026-10-23 (ans Ende angehaengt): market_value steht in der Kurs-Waehrung (USD bei einer US-Notierung), die
    -- Zeile traegt sonst nur die Buchwert-Waehrung (h.currency) -> price_currency macht das fuer freies SQL sichtbar;
    -- asset_class fuer den Anlageklassen-Schritt des Beraters (ungetaggte/unmapped Positionen benennen).
    lp.price_currency,
    h.asset_class
FROM finance.depot_holdings h
JOIN finance.accounts a ON a.id = h.account_id
LEFT JOIN latest_price lp ON lp.symbol = h.symbol
WHERE h.shares > 0;   -- hide fully sold-off positions (shares=0)

-- ============================================================
-- VIEW: Eltern-Scope-Cashflow (Multi-Member WS-3a, D2 — Custodial off-budget)
-- Anders als monthly_cashflow_overview (= Gesamt-Familie, Transfers strukturell neutral) zeigt diese
-- View den ELTERN-Blick: ein Eltern->Kind-Transfer verlaesst das Eltern-Budget und zaehlt als AUSGABE
-- (Geld bleibt im Familienvermoegen, ist aber dem Kind geschenkt). Standard YNAB/Actual: Transfer auf ein
-- off-budget-Konto = kategorisierte Ausgabe. Erkennung AUSSCHLIESSLICH ueber die Owner-ROLLE des Kontos
-- (owner_person_id -> role='child' via core.fn_household_persons(), dem publizierten DEFINER-Lesefenster —
-- finance liest agent.persons NIE direkt, D10), NIE ueber Verwendungszweck/Text. Regeln:
--   * Quell-Konto-Owner = child  -> RAUS (Kind-eigene Bewegung, kein Eltern-Cashflow; z. B. Kind-Sparplan).
--   * Transfer (target_account_id gesetzt): NUR rein, wenn Ziel-Konto-Owner = child (Eltern->Kind = Ausgabe);
--     own<->own / Eltern->Eltern-Transfer bleibt NEUTRAL (raus) — WS-2 own<->own unangetastet.
--   * Nicht-Transfer (target NULL) eines Nicht-Kind-Kontos -> zaehlt wie im Familie-Scope.
-- Doppelzaehl-Schutz: im 200-EUR-Szenario zaehlt der Eltern-Scope den Transfer (-200), der Familie-Scope den
-- Kind-Sparplan (-200) — nie beide in einem Scope. Der freie Transfer-name bleibt unveraendert (kein gespeichertes
-- "Sparen fuers Kind"); is_child_transfer ist ein abgeleitetes Anzeige-Label (render-at-fetch).
-- Audit Paket 3: Klasse + EUR-Anteile aus recurring_cashflow_classified (dieselbe Klassifikation wie die Familie).
-- Im Eltern-Blick wird ein Eltern->Kind-Transfer OHNE Sparziel (Familie: 'transfer') zu 'consumption' (Geschenk);
-- eine Sparziel-Rate in einen eigenen Topf (saving) bleibt drin, own<->own sonst raus.
-- ============================================================
CREATE VIEW finance.parent_cashflow_overview AS
SELECT
    c.id,
    c.name,
    c.amount,
    c.schedule_interval,
    c.schedule_unit,
    c.schedule_days_of_month,
    c.monthly_equivalent,
    c.account_id,
    c.account_name,
    c.status,
    c.valid_from,
    c.valid_to,
    c.currency,
    c.monthly_equivalent_eur,
    -- abgeleitetes Label (kein gespeicherter Wert): Eltern->Kind-Transfer
    (c.target_account_id IS NOT NULL AND tgtp.role = 'child') AS is_child_transfer,
    c.last_valid_day,
    c.target_account_id,
    CASE WHEN c.cashflow_class = 'transfer' THEN 'consumption' ELSE c.cashflow_class END AS cashflow_class,
    c.income_eur,
    CASE WHEN c.cashflow_class = 'transfer' THEN c.monthly_equivalent_eur ELSE c.consumption_eur END AS consumption_eur,
    c.principal_eur,
    c.saving_eur,
    c.fx_gap
FROM finance.recurring_cashflow_classified c
LEFT JOIN core.fn_household_persons() srcp ON srcp.person_id = c.account_owner_person_id
LEFT JOIN finance.accounts ta ON ta.id = c.target_account_id
LEFT JOIN core.fn_household_persons() tgtp ON tgtp.person_id = ta.owner_person_id
WHERE srcp.role IS DISTINCT FROM 'child'                       -- Kind-eigene Bewegungen raus
  AND (c.target_account_id IS NULL                             -- Nicht-Transfer
       OR tgtp.role = 'child'                                  -- Eltern->Kind-Transfer
       OR c.cashflow_class IN ('saving', 'saving_internal'));  -- Sparziel-Rate in einen eigenen Topf

-- ============================================================
-- VIEW: Cashflow-Summen je Scope (Audit Paket 3) — EINE Aggregation fuer Familie ('family') und Eltern ('parent')
-- Genau eine Zeile je Scope (VALUES-Liste, auch ohne Zahlungen). Summiert die Klassen-Anteile (EUR, Ausgaben <= 0):
--   monthly_income / monthly_consumption (inkl. Kreditzins) / monthly_principal (Tilgung)
--   monthly_obligations    = Konsum + Tilgung (Pflichtausgaben; Basis Notreserve/Runway)
--   monthly_free           = Einnahmen + Pflichtausgaben (frei verfuegbar; < 0 = cashflow_coverage)
--   monthly_saving         = Sparplaene + Sparziel-Raten + Vorsorge-Beitraege (ohne gegenfinanzierten Anteil)
--   monthly_account_change = frei + Sparen = echte Kontoveraenderung (< 0 bei frei >= 0 = savings_squeeze)
--   has_fx_gap             = eine Zeile ohne EUR-Kurs (Summen dann unvollstaendig, nie still 0)
-- COALESCE je Summe: eine Klasse ohne Zeilen (oder nur mit FX-Luecken) ist 0, nie NULL -> die abgeleiteten
-- Spalten kippen nie still auf NULL; leere Quelle = alles 0 + Zaehler 0 (Konsumenten guarden darauf).
-- Bewusst NEUE Namen (frueher monthly_expenses/monthly_net + monthly_liquidity_summary.liquidity_net):
-- gespeicherte Alt-Abfragen schlagen laut fehl statt still umzudeuten. Insurances laufen ueber ihre rp.
-- ============================================================
CREATE VIEW finance.cashflow_summary_by_scope AS
SELECT sc.scope,
       t.inc                        AS monthly_income,
       t.cons                       AS monthly_consumption,
       t.princ                      AS monthly_principal,
       t.cons + t.princ             AS monthly_obligations,
       t.inc + t.cons + t.princ     AS monthly_free,
       t.sav                        AS monthly_saving,
       t.inc + t.cons + t.princ + t.sav AS monthly_account_change,
       t.has_fx_gap, t.income_count, t.consumption_count, t.loan_count, t.saving_count
FROM (VALUES ('family'), ('parent')) sc(scope)
CROSS JOIN LATERAL (
    SELECT COALESCE(sum(r.income_eur), 0)      AS inc,
           COALESCE(sum(r.consumption_eur), 0) AS cons,
           COALESCE(sum(r.principal_eur), 0)   AS princ,
           COALESCE(sum(r.saving_eur), 0)      AS sav,
           COALESCE(bool_or(r.fx_gap), false)  AS has_fx_gap,
           count(*) FILTER (WHERE r.cashflow_class = 'income')      AS income_count,
           count(*) FILTER (WHERE r.cashflow_class = 'consumption') AS consumption_count,
           count(*) FILTER (WHERE r.cashflow_class = 'loan')        AS loan_count,
           count(*) FILTER (WHERE r.cashflow_class = 'saving')      AS saving_count
    FROM (SELECT cashflow_class, income_eur, consumption_eur, principal_eur, saving_eur, fx_gap
          FROM finance.monthly_cashflow_overview WHERE sc.scope = 'family'
          UNION ALL
          SELECT cashflow_class, income_eur, consumption_eur, principal_eur, saving_eur, fx_gap
          FROM finance.parent_cashflow_overview WHERE sc.scope = 'parent') r
) t;

-- ============================================================
-- VIEW: Monthly cashflow summary (Single-Row, Familie) = cashflow_summary_by_scope 'family'.
-- Gelesen von fn_advisor_review (cashflow_coverage/savings_squeeze/Digest) und den Write-Folds.
-- ============================================================
CREATE VIEW finance.monthly_cashflow_summary AS
SELECT monthly_income, monthly_consumption, monthly_principal, monthly_obligations, monthly_free, monthly_saving,
       monthly_account_change, has_fx_gap, income_count, consumption_count, loan_count, saving_count
FROM finance.cashflow_summary_by_scope WHERE scope = 'family';

-- ============================================================
-- VIEW: Eltern-Scope-Cashflow Summary (Single-Row) = cashflow_summary_by_scope 'parent'.
-- Gelesen von fn_liquidity_snapshot (monthly_obligations = Pflicht-Basis fuer Notreserve/Runway, selber
-- Scope wie das freie Cash ohne Kinderkonten).
-- ============================================================
CREATE VIEW finance.parent_cashflow_summary AS
SELECT monthly_income, monthly_consumption, monthly_principal, monthly_obligations, monthly_free, monthly_saving,
       monthly_account_change, has_fx_gap, income_count, consumption_count, loan_count, saving_count
FROM finance.cashflow_summary_by_scope WHERE scope = 'parent';

-- ============================================================
-- VIEW: Loan summary (single row aggregate)
-- Aggregates OUTSTANDING loans (finance.fn_loan_is_outstanding = active ODER paused, Audit Paket 2): total_debt
-- zaehlt beide (vorher nur active -> Advisor debt_total ohne pausierte Kredite, die im Vermoegen aber zaehlten);
-- die Monatswerte (Rate, Zins, Tilgung) nur aktive (ein pausierter Kredit zahlt gerade nicht).
-- total_debt is negative (Restschuld). has_fx_gap (am Ende): Restschuld in Fremdwaehrung ohne Kurs.
-- ============================================================
CREATE VIEW finance.loan_summary AS
SELECT
    count(*) FILTER (WHERE status = 'active')             AS active_loan_count,
    -- Multi-Waehrung: alle Geldsummen in EUR-Basis konvertiert (mixed-currency-Summe waere sonst falsch).
    sum(current_remaining_debt_eur)                       AS total_debt,                                    -- negative, EUR
    sum(finance.fn_to_eur(monthly_annuity, currency)) FILTER (WHERE status = 'active')      AS total_monthly_payment,
    -- Zins/Tilgung nur aus der aktuellen Restschuld (die Ursprungs-Summen entfielen mit finance:V025):
    sum(finance.fn_to_eur(monthly_interest_current, currency)) FILTER (WHERE status = 'active')  AS total_monthly_interest,   -- aus aktueller Restschuld
    sum(finance.fn_to_eur(monthly_principal_current, currency)) FILTER (WHERE status = 'active') AS total_monthly_principal,  -- Rate - Zins
    count(*) FILTER (WHERE status = 'paused')             AS paused_loan_count,
    COALESCE(bool_or(current_remaining_debt <> 0 AND current_remaining_debt_eur IS NULL), false) AS has_fx_gap
FROM finance.loan_overview
WHERE finance.fn_loan_is_outstanding(status);

-- ============================================================
-- VIEW: Gesamtvermoegen nach Anlageklasse (WS2b — Core-Advisor-Engine)
-- Eine Zeile je (bucket, asset_class) mit EUR-Wert; Quelle der per-Block-Allokations-Drift
-- (finance.fn_advisor_review). bucket = Entitaets-Typ-Diskriminator -> die Drift-fn weiss, was
-- HANDELBAR ist (Rebalancing nur Depot + liquides Cash netto; Festgeld/Immobilie/Vorsorge/p2p/Kredit nie im Drift).
-- Klassen-Herkunft (Owner-Lock, docs/package-contract + packages/finance/CLAUDE.md):
--   * Depot-Positionen (depot_holdings, shares>0): bucket='depot', asset_class = der Tag (NULL = ungetaggt
--     -> null_tag-Report); Wert = shares x juengstem market_prices.price (Fallback Buchwert avg, bis ein
--     Kurs vorliegt) in EUR.
--   * Cash (Giro/Tagesgeld): bucket='cash', Wert = BRUTTO-balance (WS-B: das Earmark-Netting via
--     savings_goal_allocations ist mit dem Tabellen-DROP entfallen; das FIRE-Topf-Netting ist bewusst nach
--     BACKLOG verschoben — Reserve-Fundament zuerst). Das Depot-Verrechnungs-/Tagesgeldkonto Typ cash zaehlt voll.
--   * WS3: Festgeld (fixed_deposit): EIGENE bucket='fixed_deposit'-Klasse, Wert = BRUTTO-balance, aber
--     tradeable=false -> Stabilitaets-Baustein, zaehlt in Net-Worth/FIRE-Pot, NICHT im Rebalancing-Nenner
--     (illiquide bis Faelligkeit; Experten-Modell Bengen/Morningstar-Bucket).
--   * p2p: bucket='p2p' (Alternativ, NICHT handelbar). Kredit (loan): bucket='loan' (negativ, Verbindlichkeit).
--   * REINE Depot-Konten (stocks_depot/crypto_depot, Saldo strukturell 0): NICHT enthalten (Wert steckt in
--     den Holdings -> Doppelzaehl-Schutz).
--   * Immobilie -> bucket='real_estate' (Wert current_value, gilt als EUR), Vorsorge -> bucket='pension'
--     (current_value); abgeleitet aus dem Entitaets-Typ, KEIN Tag. Kredite/Restschuld stehen separat im
--     loan-bucket (kein Netten ins real_estate -> sauberes Brutto-Asset + separate Verbindlichkeit).
-- Multi-Member (WS-3a Custodial-Scope): jede Zeile traegt jetzt owner_person_id (Eigentuemer-Person aus
--   accounts/real_estate/pension; Depot ERBT ueber das Konto via JOIN; NULL = Haushalt/gemeinsam). Drei
--   Sichten auf EINE Datenbasis: T1 Gesamt-Familie (Caller lassen owner_person_id aus dem GROUP BY -> SUM
--   kollabiert, additiv) · T2 Eltern-/FIRE-Pool (Konsument schliesst role='child' via core.fn_household_persons()
--   aus) · T3 Pro-Kind (WHERE owner_person_id = Kind-Slug). owner_person_id ist roher Slug (kein Window-Join in
--   der View -> finance_ro liest sie unveraendert); die Rollen-Aufloesung macht der Konsument.
-- ============================================================
CREATE VIEW finance.networth_by_asset_class AS
WITH latest_price AS (
    SELECT DISTINCT ON (mp.symbol) mp.symbol, mp.price, mp.currency, mp.as_of
    FROM finance.market_prices mp
    ORDER BY mp.symbol, mp.as_of DESC
),
parts AS (
    -- Depot-Positionen: Marktwert (Fallback Buchwert), Klasse = asset_class-Tag (NULL = ungetaggt);
    -- Owner ERBT ueber das Depot-Konto (JOIN accounts) — z. B. Kinder-Custodial-Depot.
    SELECT 'depot'::text AS bucket,
           h.asset_class AS asset_class,
           da.owner_person_id AS owner_person_id,
           -- Phase M: den Live-Kurs in SEINER gespeicherten Waehrung (lp.currency = COALESCE(quote_currency,
           -- currency)) nach EUR konvertieren, NICHT in h.currency -- sonst Fehl-Umrechnung, wenn die
           -- Quote-Waehrung von der Aufnahme-Waehrung abweicht (US-Listing in USD, Position EUR gefuehrt).
           -- Fallback = Buchwert in h.currency, bis ein Kurs vorliegt.
           CASE WHEN lp.price IS NOT NULL
                THEN finance.fn_to_eur(h.shares * lp.price, lp.currency)
                ELSE finance.fn_to_eur(h.shares * h.average_purchase_price, h.currency)
           END AS value_eur,
           -- Nativwert (fuer has_fx_gap): Kurs-Wert, sonst Buchwert; ohne beides keine FX-Luecke (fehlende Daten).
           COALESCE(h.shares * lp.price, h.shares * h.average_purchase_price) AS value_native
    FROM finance.depot_holdings h
    JOIN finance.accounts da ON da.id = h.account_id
    LEFT JOIN latest_price lp ON lp.symbol = h.symbol
    WHERE h.shares > 0

    UNION ALL
    -- Cash/Festgeld = BRUTTO-balance (WS-B: Earmark-Netting via savings_goal_allocations entfallen, FIRE-Topf-
    -- Netting nach BACKLOG verschoben); WS3: Festgeld eigene Klasse; p2p eigene Klasse; Kredit negativ;
    -- reine Depot-Konten raus.
    SELECT CASE a.account_type WHEN 'p2p' THEN 'p2p' WHEN 'loan' THEN 'loan' WHEN 'fixed_deposit' THEN 'fixed_deposit' ELSE 'cash' END AS bucket,
           CASE a.account_type WHEN 'p2p' THEN 'p2p' WHEN 'loan' THEN 'loan' WHEN 'fixed_deposit' THEN 'fixed_deposit' ELSE 'cash' END AS asset_class,
           a.owner_person_id AS owner_person_id,
           finance.fn_to_eur(b.balance, a.currency) AS value_eur,  -- cash/fixed_deposit brutto, p2p (Nennwert), loan (negativ)
           b.balance AS value_native
    FROM finance.accounts a
    JOIN finance.account_balances b ON b.account_id = a.id
    WHERE a.status = 'active'
      AND a.account_type IN ('cash','fixed_deposit','p2p','loan')

    UNION ALL
    -- Immobilie (Brutto-Wert; gilt als EUR)
    SELECT 'real_estate', 'real_estate', re.owner_person_id, re.current_value, re.current_value
    FROM finance.real_estate re
    WHERE re.status = 'active' AND re.current_value IS NOT NULL

    UNION ALL
    -- Altersvorsorge (akkumulierter Wert; NULL bei unbekannt -> raus)
    SELECT 'pension', 'pension', p.owner_person_id, p.current_value, p.current_value
    FROM finance.pension p
    WHERE p.status = 'active' AND p.current_value IS NOT NULL
)
SELECT bucket,
       asset_class,
       owner_person_id,
       (bucket IN ('depot','cash')) AS tradeable,   -- handelbar/rebalancierbar (Drift-Nenner)
       round(sum(value_eur), 2)     AS value_eur,
       -- Audit Paket 2 (Punkt 11): ein Wert ohne Wechselkurs faellt sonst STILL als 0 aus value_eur (sum ignoriert
       -- NULL) -> als Luecke melden. Ein fehlender Marktpreis ist keine Luecke (Buchwert-Fallback oben).
       COALESCE(bool_or(value_native <> 0 AND value_eur IS NULL), false) AS has_fx_gap
FROM parts
GROUP BY bucket, asset_class, owner_person_id;

-- ============================================================
-- VIEW: Depot-Reserve-Deckungs-Waechter  (WS-B Phase S)
-- Je AKTIVEM Depot-Konto: der Live-Marktwert vs. der darauf fuer aktive Sparziele RESERVIERTE Betrag (Σ des
-- append-only savings_goal_reserve_entries-Journals). Spiegelt account_reserve_status (Cash, Saldo-basiert),
-- aber MARKT-WERT-basiert (ein Depot traegt keine Buchungen -> kein Saldo; der Wert steckt in den shares).
--   market_value = SUM(depot_holdings_overview.market_value_eur) je Depot (EUR; NULL wenn KEINE gehaltene
--     Position einen Live-Kurs hat -> Deckung nicht ermittelbar).
--   reserved = Σ savings_goal_reserve_entries.delta_native (je Zeile via fn_to_eur nach EUR) ueber AKTIVE Ziele (Join status='active' -> ein
--     completed/cancelled-Ziel gibt seine Depot-Reserve frei; ein hart-geloeschtes cascadet ohnehin weg).
--   breach = COALESCE(market_value,0) < reserved  (reserved>0). NULL-Preis -> COALESCE 0 -> breach=TRUE: ein
--     nicht ermittelbarer Marktwert deckt NICHTS, nie still FALSE (3-wertige Logik vermieden) — Edge-Reviewer-Pflicht.
--   fx_missing (WP-3c) = market_value IS NULL AND reserved>0: die Deckung ist NICHT ERMITTELBAR (kein Live-Kurs
--     ODER fehlender FX-Kurs) -> der Advisor unterscheidet damit „Kurs fehlt" von „echt unterdeckt" (breach bleibt
--     fail-loud TRUE, aber der Alert-Text sagt bei fx_missing ehrlich „nicht ermittelbar" statt Fehldiagnose).
--   shortfall = GREATEST(reserved - COALESCE(market_value,0), 0) (nie NULL).
-- ADVISORY (wie account_reserve_status): kein Block; der Advisor wendet die Pace-bewusste Smart-Unterdrueckung an.
-- Konsumenten: fn_advisor_review (Deckungs-Dialog), finance_ro (Drill-down). (WP-5a: fn_reserve_breach liest
-- diese View NICHT mehr — sein Depot-Zweig war toter Code und wurde entfernt.)
-- ============================================================
CREATE VIEW finance.depot_reserve_status AS
SELECT a.id                                             AS account_id,
       a.name                                           AS account_name,
       mv.market_value                                  AS market_value,   -- EUR; NULL = kein Live-Kurs
       COALESCE(res.reserved, 0)                        AS reserved,
       GREATEST(COALESCE(res.reserved, 0) - COALESCE(mv.market_value, 0), 0) AS shortfall,
       (COALESCE(res.reserved, 0) > 0 AND COALESCE(mv.market_value, 0) < COALESCE(res.reserved, 0)) AS breach,
       (mv.market_value IS NULL AND COALESCE(res.reserved, 0) > 0)          AS fx_missing   -- WP-3c: Deckung nicht ermittelbar
FROM finance.accounts a
LEFT JOIN (
    SELECT account_id, sum(market_value_eur) AS market_value   -- NULL wenn keine Position einen Kurs hat
    FROM finance.depot_holdings_overview                        -- bereits shares>0-gefiltert
    GROUP BY account_id
) mv ON mv.account_id = a.id
LEFT JOIN (
    SELECT e.account_id, sum(finance.fn_to_eur(e.delta_native, e.currency, e.value_date)) AS reserved   -- WP-3b: Journal je Depot nach EUR, nur aktive Ziele
    FROM finance.savings_goal_reserve_entries e
    JOIN finance.savings_goals g ON g.id = e.savings_goal_id
    WHERE g.status = 'active'
    GROUP BY e.account_id
) res ON res.account_id = a.id
WHERE a.status = 'active'
  AND a.account_type IN ('stocks_depot', 'crypto_depot');

-- ============================================================
-- VIEW: Sparziel-Reserve-Aufschluesselung  (WS-B Phase S — "wo liegt mein Ziel-Geld?")
-- Je (Ziel, Quelle, Konto) eine Zeile: der Cash-Anteil je getaggtem Konto (transactions.savings_goal_id) UND
-- der Depot-Anteil je Depot (Σ savings_goal_reserve_entries). WP-3b: reserved_amount ist in EUR (fn_to_eur je
-- Zeile), damit die Aufschluesselung ueber verschieden-waehrige Konten aufsummiert werden darf (fruehere
-- Roh-Native-Summe mischte still verschiedene Waehrungen). Reiner Drill-down/Anzeige-Helfer fuer den Advisor-Digest.
-- ============================================================
CREATE VIEW finance.savings_goal_reserve_breakdown AS
SELECT t.savings_goal_id          AS goal_id,
       'cash'::text               AS source,
       t.account_id,
       a.name                     AS account_name,
       sum(finance.fn_to_eur(t.amount, a.currency, t.transaction_date)) AS reserved_amount
FROM finance.transactions t
JOIN finance.accounts a ON a.id = t.account_id
WHERE t.savings_goal_id IS NOT NULL
GROUP BY t.savings_goal_id, t.account_id, a.name
UNION ALL
SELECT e.savings_goal_id          AS goal_id,
       'depot'::text              AS source,
       e.account_id,
       a.name                     AS account_name,
       sum(finance.fn_to_eur(e.delta_native, e.currency, e.value_date)) AS reserved_amount
FROM finance.savings_goal_reserve_entries e
JOIN finance.accounts a ON a.id = e.account_id
GROUP BY e.savings_goal_id, e.account_id, a.name;
