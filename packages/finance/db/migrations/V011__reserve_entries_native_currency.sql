-- ============================================================
-- V011 (finance) — savings_goal_reserve_entries: delta_eur -> delta_native + currency + value_date (WP-3b).
--
--   WARUM: Der Depot-Anteil einer Sparziel-Reserve wurde als EUR-Betrag (delta_eur) gespeichert, aber
--   fn_book_stock_buy schrieb den ROHEN Nativ-Betrag (Depot-Waehrung) hinein -> bei einem Nicht-EUR-Depot
--   still falsch (KRW-Betrag in einer EUR-Spalte). Der naive Fix "beim Insert via fn_to_eur umrechnen" scheitert
--   am NOT-NULL-CHECK (fn_to_eur = NULL bei fehlendem Kurs -> Crash -> blockt den Kauf, verletzt "nie blocken")
--   UND bricht die Konservierung von savings_goal_progress.current_amount (Cash-Bein wird in der VIEW live
--   konvertiert, ein eingefrorener EUR-delta driftet dagegen bei Kurs-Revision). Loesung: den Nativ-Betrag +
--   seine Waehrung + das Umrechnungsdatum SPEICHERN, die EUR-Umrechnung macht erst die VIEW (fn_to_eur) —
--   beide Reserve-Legs (Cash + Depot) tragen dieselbe Live-Semantik, kein Drift, kein NULL-Crash am Insert.
--
--   TRANSFORM (idempotent, Fresh-DB = no-op weil finance.tables_init die Zielspalten direkt anlegt):
--     (1) delta_eur -> delta_native umbenennen (der CHECK-Ausdruck folgt dem Rename automatisch).
--     (2) currency char(3) NOT NULL DEFAULT 'EUR' (FK finance.currencies) — Bestand ist ausnahmslos EUR
--         (delta_eur war EUR) -> DEFAULT backfillt korrekt.
--     (3) value_date date NOT NULL DEFAULT CURRENT_DATE — Bestand ist EUR (value_date fuer die Umrechnung
--         irrelevant, EUR->EUR ist Identitaet).
--
-- APPLY-ORDER: Inits (legen Zielspalten an) -> V (hier, transformiert Bestand) -> R (Views lesen delta_native).
-- Re-run-sicher (alle Schritte IF EXISTS / IF NOT EXISTS). Kein REVOKE-Tail betroffen.
-- ============================================================

DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'finance'
          AND table_name = 'savings_goal_reserve_entries'
          AND column_name = 'delta_eur'
    ) THEN
        ALTER TABLE finance.savings_goal_reserve_entries RENAME COLUMN delta_eur TO delta_native;
    END IF;
END $$;

ALTER TABLE finance.savings_goal_reserve_entries
    ADD COLUMN IF NOT EXISTS currency char(3) NOT NULL DEFAULT 'EUR' REFERENCES finance.currencies(code);

ALTER TABLE finance.savings_goal_reserve_entries
    ADD COLUMN IF NOT EXISTS value_date date NOT NULL DEFAULT CURRENT_DATE;
