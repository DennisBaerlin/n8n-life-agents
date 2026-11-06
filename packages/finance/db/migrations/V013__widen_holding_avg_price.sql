-- ============================================================
-- V013 (finance) — depot_holdings.average_purchase_price numeric(12,4) -> numeric(20,8) (Audit Paket 2, Punkt 13).
--
--   WARUM: 4 Nachkommastellen machten Mini-Kurse (Krypto-Bruchteile, Penny-Token) unter 0.0001 zu 0 bzw. 0.0001
--   (1.000.000 Stueck fuer 50 EUR -> Durchschnitt 0.0001 statt 0.00005 -> Buchwert 100 statt 50). Neue Praezision =
--   market_prices.price (20,8); fn_holding_avg_cost rundet auf 8 Stellen (Init).
--
--   REIHENFOLGE (Muster V006): PostgreSQL blockt ALTER COLUMN TYPE, solange eine View die Spalte referenziert. Beim
--   inkrementellen Apply liegen die finance-Views aus dem letzten Lauf vor -> hier ZUERST jede finance-View droppen,
--   die an der Spalte haengt (CASCADE faengt Folge-Views), DANN ALTER. R__finance_views.sql (laeuft als R__ NACH den
--   V; aendert sich in diesem Release ohnehin) baut sie neu auf. Haengt eine View AUSSERHALB von finance an der
--   Spalte, bricht die Migration ab (deren R__ liefe nicht neu -> CASCADE wuerde sie still verlieren).
--   DANACH die Durchschnitte neu rechnen: der Init-Backfill lief vor dieser V noch in die alte (12,4)-Spalte.
--
--   Fresh -Reset: Init legt die Spalte schon als (20,8) an, die Views existieren noch nicht -> ALTER = no-op.
-- ============================================================

DO $$
DECLARE
    v_view    regclass;
    v_foreign text;
BEGIN
    SELECT string_agg(DISTINCT c.oid::regclass::text, ', ') INTO v_foreign
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    JOIN pg_class c   ON c.oid = r.ev_class
    JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
    WHERE d.refobjid = 'finance.depot_holdings'::regclass
      AND a.attname = 'average_purchase_price'
      AND c.relnamespace <> 'finance'::regnamespace;
    IF v_foreign IS NOT NULL THEN
        RAISE EXCEPTION 'V013: views outside schema finance depend on depot_holdings.average_purchase_price (%); '
                        'drop/rebuild them around this migration.', v_foreign;
    END IF;

    FOR v_view IN
        SELECT DISTINCT c.oid::regclass
        FROM pg_depend d
        JOIN pg_rewrite r ON r.oid = d.objid
        JOIN pg_class c   ON c.oid = r.ev_class
        JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE d.refobjid = 'finance.depot_holdings'::regclass
          AND a.attname = 'average_purchase_price'
          AND c.oid <> 'finance.depot_holdings'::regclass
    LOOP
        EXECUTE format('DROP VIEW IF EXISTS %s CASCADE', v_view);
    END LOOP;
END $$;

ALTER TABLE finance.depot_holdings ALTER COLUMN average_purchase_price TYPE numeric(20,8);

UPDATE finance.depot_holdings h
SET average_purchase_price = finance.fn_holding_avg_cost(h.id)
WHERE EXISTS (SELECT 1 FROM finance.transactions t WHERE t.holding_id = h.id)
  AND h.average_purchase_price IS DISTINCT FROM finance.fn_holding_avg_cost(h.id);
