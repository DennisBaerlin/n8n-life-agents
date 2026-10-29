-- ============================================================
-- fn_standing_orders (READ, STABLE) -- die Dauerauftraege, die der Haushalt bei seiner Bank selbst einrichtet
--   („Bank-To-do" im Ziele-Bildschirm, Abschnitt „Dauerauftraege je Konto"). Je Kette das massgebliche Glied
--   (fn_recurring_effective: laufend oder erst kommend), status active, valid_to leer oder kuenftig.
--   kind 'transfer' = Uebertrag eigenes Konto -> eigenes Konto (target_account_id gesetzt), auch Haushalts-Umbuchungen
--   kind 'debit'    = Spar-Abfluss ohne Ziel-Konto, der kein Sparplan ist (Vorsorge-Beitrag, Sparziel-Rate ohne Topf)
--   Nie: Kredit-Raten (Ketten-Kopf in loans, Quelle ein Kreditkonto), Sparplan-Ausfuehrungen (stehen im Abschnitt
--   Sparplaene), Eingaenge und sonstige Lastschriften (Strom, Abo: richtet der Glaeubiger ein).
--   Bei uns anders (package-contract §8): die Klassifikation steht hier statt in recurring_cashflow_classified, weil
--   diese View nur HEUTE laufende Zahlungen kennt und die Bank-To-do gerade die kommenden braucht.
--   RUECKGABE: (rp_id, head_id, kind)
--   Tests: tests/db/finance/test_fn_app_screen_goals.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_standing_orders()
RETURNS TABLE(rp_id int, head_id int, kind text)
LANGUAGE sql STABLE AS $$
    WITH h AS (
        SELECT DISTINCT finance.fn_recurring_lineage_head(r.id) AS head FROM finance.recurring_payments r
    ), e AS (
        SELECT h.head, finance.fn_recurring_effective(h.head, current_date) AS cur FROM h
    )
    SELECT r.id, e.head, CASE WHEN r.target_account_id IS NOT NULL THEN 'transfer' ELSE 'debit' END
    FROM e
    JOIN finance.recurring_payments r ON r.id = e.cur
    JOIN finance.accounts sa ON sa.id = r.account_id
    WHERE r.status = 'active' AND (r.valid_to IS NULL OR r.valid_to > current_date)
      AND sa.account_type <> 'loan'
      AND NOT EXISTS (SELECT 1 FROM finance.loans l WHERE l.recurring_payment_id = e.head)
      AND NOT EXISTS (SELECT 1 FROM finance.savings_plans sp WHERE sp.recurring_payment_id = e.head)
      AND (r.target_account_id IS NOT NULL
           OR (r.amount < 0 AND (EXISTS (SELECT 1 FROM finance.pension p WHERE p.recurring_payment_id = e.head)
                                 OR EXISTS (SELECT 1 FROM finance.savings_goals g WHERE g.recurring_payment_id = e.head))))
    ORDER BY r.id;
$$;
