-- ============================================================
-- fn_statement_diff_candidates (READ, STABLE) -- Buchungen mit gleichem Betrag wie eine Abweichung des Monats-Checks
--   Eine Abweichung kann auf den Cent einer vorhandenen Buchung entsprechen; statt die Pruefung an den Nutzer zurueckzugeben,
--   liefert die fn die Kandidaten als Daten; ein Storno o. Ae. laeuft weiter ueber das jeweilige Tool mit Karte.
--   Eingabe: p_account, p_targets = [{for, amount}] (Ziele mit Betrag 0 entfallen, gleicher Betrag nur beim ersten Ziel),
--   p_from/p_to = Zeitraum des Auszugs, p_exclude = Buchungen, die der Auszug schon belegt. Gleiches Konto: |amount| = |Ziel|,
--   Datum bis p_to+5. Andere eigene Konten: umgekehrtes Vorzeichen, Datum im Zeitraum +-5 Tage. Je Ziel hoechstens 3, gleiches
--   Konto zuerst, juengste zuerst.
--   RUECKGABE: [{for, transaction_id, date, amount, category, description, account_name, same_account}] (nie NULL).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_statement_diff_candidates(p_account int, p_targets jsonb, p_from date, p_to date, p_exclude int[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_res JSONB;
BEGIN
    WITH tg AS (
        SELECT DISTINCT ON (abs(z.amt)) z.f, z.amt
        FROM (SELECT e->>'for' AS f, (e->>'amount')::numeric AS amt, o FROM jsonb_array_elements(p_targets) WITH ORDINALITY AS x(e, o)) z
        WHERE z.amt <> 0
        ORDER BY abs(z.amt), z.o
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('for', c.f, 'transaction_id', c.id, 'date', c.transaction_date, 'amount', c.amount,
               'category', c.category, 'description', c.description, 'account_name', c.account_name, 'same_account', c.same)
               ORDER BY c.f, c.rn), '[]'::jsonb)
    INTO v_res
    FROM (
        SELECT tg.f, t.id, t.transaction_date, t.amount, t.category::text AS category, t.description, a.name AS account_name,
               t.account_id = p_account AS same,
               row_number() OVER (PARTITION BY tg.f ORDER BY (t.account_id = p_account) DESC, t.transaction_date DESC, t.id DESC) AS rn
        FROM tg
        JOIN finance.transactions t ON abs(t.amount) = abs(tg.amt)
        JOIN finance.accounts a ON a.id = t.account_id
        WHERE NOT (t.id = ANY(p_exclude))
          AND ((t.account_id = p_account AND t.transaction_date <= p_to + 5)
               OR (t.account_id <> p_account AND sign(t.amount) = -sign(tg.amt)
                   AND t.transaction_date BETWEEN p_from - 5 AND p_to + 5))
    ) c
    WHERE c.rn <= 3;
    RETURN v_res;
END;
$$;
