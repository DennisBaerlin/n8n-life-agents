-- ============================================================
-- fn_upcoming_payments (READ, STABLE) -- offene Dauerauftrags-Vorkommen eines Zeitraums mit ihrem Buchungsbetrag
--   Die EINE Quelle fuer „was geht wann von welchem Konto ab / auf welches Konto ein“: Kontovorschau
--   (finance.fn_account_outlook) und Mini-App-Bildschirm „Zahlungen“ (finance.fn_app_screen_payments).
--   Vorkommen = finance.fn_recurring_due_open(p_from, p_until) (Status, Gueltigkeit, gebucht/uebersprungen); p_from wird
--   nie auf heute hochgesetzt (die Vorschau startet am Tag nach dem bestaetigten Stand).
--   amount         = Betrag, den die Buchung nehmen wuerde (fn_recurring_occurrence_amount; Kredit-Schlussrate =
--                    Abloesebetrag), signiert aus Sicht von account_id (Quelle); Fallback der Zeilenbetrag.
--   planned_amount = recurring_payments.amount roh (die Ziel-Seite eines Uebertrags rechnet abs() davon).
--   RUECKGABE: (recurring_payment_id, due_date, account_id, target_account_id, amount, planned_amount)
--   Tests: tests/db/finance/test_fn_upcoming_payments.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_upcoming_payments(p_from date, p_until date)
RETURNS TABLE(recurring_payment_id int, due_date date, account_id int, target_account_id int, amount numeric,
              planned_amount numeric)
LANGUAGE sql STABLE AS $$
    SELECT o.recurring_payment_id, o.due_date, r.account_id, r.target_account_id,
           COALESCE(finance.fn_recurring_occurrence_amount(r.id, o.due_date), r.amount),
           r.amount
    FROM finance.fn_recurring_due_open(p_from, p_until) o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id;
$$;
