-- ============================================================
-- fn_recurring_valid_from (STABLE, read-only) — ab wann eine NEU angelegte wiederkehrende Zahlung zaehlt
--   Die EINE Regel aller create-fns mit recurring_payment (Versicherung, Kredit, Vorsorge, Dauerauftrag,
--   Dauer-Transfer, Sparziel, Sparplan): Hat das Konto einen beim Anlegen genannten Saldo
--   (accounts.opening_balance_date, gesetzt von fn_create_account), stecken alle Vorkommen VOR diesem
--   Stichtag schon in diesem Saldo -> die Zahlung gilt fruehestens ab dem Stichtag (fn_recurring_due_open
--   bietet nur Vorkommen ab valid_from an). first_payment_date bleibt unveraendert der Rhythmus-Anker.
--   Liegt der Stichtag VOR dem Anlage-Tag (Endsaldo eines Kontoauszugs = Tagesende), steckt auch der Stichtag
--   selbst im Saldo -> fruehestens der Folgetag (wie der Schnitt des Monats-Checks, der den Stichtag als bestaetigt
--   zaehlt). Ein heute genannter Saldo bleibt inklusive heute offen (ob die heutige Abbuchung schon drin ist, ist offen).
--   Konto ohne Eroeffnungssaldo -> p_from unveraendert (echte offene Faelligkeiten bleiben sichtbar).
--   RUECKGABE: GREATEST(p_from, Stichtag [+1 bei vergangenem Stichtag]) bzw. p_from.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_valid_from(p_account_id int, p_from date)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT GREATEST(p_from, COALESCE(
        (SELECT a.opening_balance_date
                + CASE WHEN a.opening_balance_date < core.fn_today(a.created_at) THEN 1 ELSE 0 END
         FROM finance.accounts a WHERE a.id = p_account_id), p_from));
$$;
