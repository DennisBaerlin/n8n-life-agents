-- ============================================================
-- V019 (finance) — Stueckpreis der Bestandsuebernahme nachtragen + spiegelnder CHECK (Rundungs-Paket 2026-10-23).
--
--   WARUM: fn_holding_avg_cost rechnete den Einstand aus dem cent-gerundeten amount zurueck. Bei einer Uebernahme ist
--   aber der GENANNTE Einstand die Wahrheit (amount ist daraus nur abgeleitet): 0.04349409 BTC @ 60772 -> amount
--   -2643.22 -> Einstand 60771.93476171 (Owner-Fund auf der Live-Instanz). Seit diesem Paket speichert
--   fn_book_stock_buy bei existing_position transactions.unit_price; diese Migration traegt ihn fuer BESTEHENDE
--   Uebernahmen nach (der avg-Trigger rechnet die Holdings beim UPDATE neu).
--
--   (1) Backfill: buy-Zeilen ohne unit_price, deren group_id eine position_takeover-Gegenbuchung hat. Der Preis kommt
--       aus der EIGENEN Buchungsbeschreibung von fn_book_stock_buy ("Kauf <stueck> <symbol> @ <preis> (Gebühr …)", aelter
--       "(Gebuehr …)"): das Token direkt vor " (Geb". Gebuehr und Stueck kommen aus den Spalten, nie aus dem Text.
--       Uebernommen wird NUR, wenn round(shares x preis + gebuehr, 2) = -amount — sonst bleibt NULL (= bisheriger Wert,
--       nichts kann falsch werden; daher kein Pre-Flight). Cast im EXCEPTION-Block (kaputter Text -> NULL).
--       Logik-Kopie im Test: tests/db/finance/test_rounding.sql [R4] (V ruft keine R__-fn: die gibt es hier noch nicht).
--   (2) CHECK finance_transactions_unit_price_chk: ein gesetzter unit_price muss zum gebuchten Betrag passen.
--       Freundlicher Weg: fn_book_stock_buy rundet den Kurs auf 8 Stellen und rechnet amount UND unit_price daraus.
--
--   APPLY-ORDER: Inits (Spalte + neue fn_holding_avg_cost) -> V (hier) -> R. Re-run-sicher (nur NULL-Zeilen;
--   DROP CONSTRAINT IF EXISTS + ADD).
-- ============================================================

-- (1) Backfill
DO $$
DECLARE
    r       RECORD;
    v_price NUMERIC;
BEGIN
    FOR r IN
        SELECT t.id, t.shares, t.order_fee, t.amount, t.description
        FROM finance.transactions t
        WHERE t.category::text = 'buy' AND t.unit_price IS NULL AND t.shares > 0 AND t.group_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM finance.transactions g WHERE g.group_id = t.group_id AND g.category::text = 'position_takeover')
    LOOP
        v_price := NULL;
        BEGIN
            v_price := round(((regexp_match(r.description, ' @ ([^ ]+) \(Geb'))[1])::numeric, 8);
        EXCEPTION WHEN others THEN v_price := NULL;
        END;
        IF v_price > 0 AND round(r.shares * v_price + COALESCE(r.order_fee, 0), 2) = -r.amount THEN
            UPDATE finance.transactions SET unit_price = v_price WHERE id = r.id;
        END IF;
    END LOOP;
END $$;

-- (2) CHECK (category::text: wie finance_transactions_position_takeover_shape)
DO $$ BEGIN
    ALTER TABLE finance.transactions DROP CONSTRAINT IF EXISTS finance_transactions_unit_price_chk;
    ALTER TABLE finance.transactions ADD CONSTRAINT finance_transactions_unit_price_chk CHECK (
        category::text <> 'buy' OR unit_price IS NULL
        OR (unit_price > 0 AND round(shares * unit_price + COALESCE(order_fee, 0), 2) = -amount)
    );
END $$;
