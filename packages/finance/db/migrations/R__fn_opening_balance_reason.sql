-- ============================================================
-- fn_opening_balance_reason (READ HELPER) -- liegt eine Bewegung im Startbetrag eines Kontos?
--   Ein beim Anlegen genannter Saldo (accounts.opening_balance_date) enthaelt alle Bewegungen bis zu seinem Stichtag; ein
--   Bein mit so einem Datum zaehlte doppelt. Kern = die eine Regel fn_recurring_valid_from(account, date) > date: vor dem
--   Stichtag immer, am Stichtag nur bei spaeterer Anlage (Endsaldo = Tagesende; Anlage am selben Tag = "morgens").
--   plpgsql wegen der alphabetisch spaeteren fn_recurring_valid_from. Konsumenten: fn_book_transfer,
--   fn_book_recurring_transfer, fn_statement_prepare (Stufe T, Pool, Dauerauftrag).
--   Eingabe: p_account_id, p_date (Datum der Bewegung).
--   Rueckgabe: NULL = nicht im Startbetrag, sonst der Grund (EN, fuer {ok:false, code:'before_opening', reason}); den naechsten
--   Schritt ergaenzt der Aufrufer.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_opening_balance_reason(p_account_id int, p_date date)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_text TEXT;
BEGIN
    IF finance.fn_recurring_valid_from(p_account_id, p_date) <= p_date THEN
        RETURN NULL;
    END IF;
    SELECT 'The starting balance of account "' || a.name || '" dated ' || a.opening_balance_date
           || ' already contains every movement up to that day, so a booking dated ' || p_date || ' would count twice.'
    INTO v_text
    FROM finance.accounts a WHERE a.id = p_account_id;
    RETURN v_text;
END;
$$;
