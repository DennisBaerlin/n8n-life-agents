-- ============================================================
-- fn_possible_duplicate_note (KARTEN-HINWEIS "MOEGLICHE DOPPELBUCHUNG", Paket DB-ist-das-Gesetz S6)
--   Ersetzt die Prompt-Regel "vor jeder Buchung 15 Tage per ILIKE durchsuchen und nachfragen" durch eine
--   deterministische, hohe Schwelle: auf p_account existiert schon eine Buchung mit GENAU diesem Betrag (mit
--   Vorzeichen) innerhalb von +-3 Tagen um p_date. Ergebnis = card_lines-Array (leer oder eine Note):
--     [{kind:'note', value:'finance.note.possible_duplicate', params:{date, amount}}]
--   Kein Block: legitime Wiederholungen (Tankstelle, Abo) bleiben buchbar, der Nutzer sieht den Hinweis auf der Karte.
--   Konsumenten: fn_book_transaction, fn_book_transfer (Abgangskonto).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_possible_duplicate_note(p_account int, p_signed_amount numeric, p_date date)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.possible_duplicate',
                   'params', jsonb_build_object('date', core.fn_ui_date(t.transaction_date),
                                                'amount', core.fn_ui_money(abs(t.amount), a.currency))))
          FROM finance.transactions t
          JOIN finance.accounts a ON a.id = t.account_id
         WHERE t.account_id = p_account
           AND t.amount = p_signed_amount
           AND abs(t.transaction_date - p_date) <= 3
         ORDER BY abs(t.transaction_date - p_date), t.id DESC
         LIMIT 1), '[]'::jsonb);
$$;
