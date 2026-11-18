-- ============================================================
-- fn_account_confirmed_until (READ, STABLE) -- bis zu welchem Tag der Stand eines Kontos bestaetigt ist
--   Die eine Adresse fuer "bestaetigt bis": spaetester Tag aus Chat-/Auszugs-Bestaetigung (last_reconciled_at),
--   Startdatum der Anlage (opening_balance_date) und Ende des juengsten Kontoauszugs. NULL = nie bestaetigt.
--   Leser: fn_statements_due (Erinnerung + Bot), fn_bank_export_facts (Vorab-Abschnitt der Tabellen-Datei).
--   Eingabe: p_account_id. Rueckgabe: date | NULL (auch bei unbekannter Konto-id).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_confirmed_until(p_account_id int)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT GREATEST(a.last_reconciled_at, a.opening_balance_date,
                    (SELECT max(b.period_end) FROM finance.bank_statements b WHERE b.account_id = a.id))
    FROM finance.accounts a
    WHERE a.id = p_account_id;
$$;
