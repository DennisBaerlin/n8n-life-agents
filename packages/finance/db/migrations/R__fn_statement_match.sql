-- ============================================================
-- fn_statement_match (READ, STABLE) -- Zuordnung der Kontoauszug-Zeilen zu erwarteten Zahlungen (Monats-Check WP-C)
--   Die EINE Zuordnungs-Adresse fuer Vorschau (fn_statement_prepare) und Buchung (fn_apply_bank_statement ruft
--   prepare erneut). Deterministisch, kein LLM. Nur Zeilen NACH p_cut (Tage bis p_cut stecken im bestaetigten Saldo).
--   Kandidaten:
--     * offene Dauerauftrags-Vorkommen dieses Kontos als Quelle (Soll-Betrag fn_recurring_occurrence_amount) oder als
--       Transfer-Ziel (+|amount|, nur gleiche Waehrung), Faelligkeit in [p_cut-10, p_period_end+5];
--     * offene Zins-Vorkommen dieses Kontos (Soll fn_interest_amount_due), nur Zeilen mit "zins" im Text;
--     * Stufe 0: schon gebuchte Dauerauftrags-/Zinsbuchungen dieses Kontos im Zeitraum (z. B. das Gegenbein aus dem
--       Auszug des Partnerkontos oder eine manuell bestaetigte Abbuchung) — werden nicht erneut gebucht.
--   Stufen (Paar Zeile x Kandidat, Vorzeichen muss stimmen):
--     0 = gebuchte Buchung: gleicher Betrag, Buchungsdatum +-5 Tage. Liegt das Buchungsdatum NACH period_end, nur wenn
--         die Buchung (alle Beine der group_id) aufs Zeilendatum verschiebbar ist (kein Bein-Konto dort abgeglichen):
--         fn_apply_bank_statement verschiebt sie, sonst zaehlte sie zusaetzlich im Rest.
--     A = Schluessel: SEPA-Mandat (Glaeubiger-ID|Mandatsreferenz) oder Gegen-IBAN eines Glieds der Vorgaenger-Kette,
--         bzw. Gegen-IBAN = Kontonummer des Transfer-Gegenkontos; Betrag 50-150 % des Solls; Faelligkeit +-10 Tage.
--     B = Betrag + Datum: Zeile 5 Tage vor bis 10 Tage nach der Faelligkeit; Betrag exakt (+-0,005) ODER, wenn ein
--         Namens-Token des Dauerauftrags (>= 4 Zeichen) im Zeilentext steht, +-5 % (mind. 2,00).
--   Zuordnung gierig in fester Ordnung (Stufe -> |Betragsabweichung| -> |Tage| -> Zeile -> Kandidat): jede Zeile und
--   jeder Kandidat hoechstens einmal (Muster YNAB/Actual: gleiche Betraege am selben Tag werden so stabil verteilt).
--   Bank-Export-Datei: Zeilen mit kind (fn_bank_export_normalize) treffen nur passende Kandidaten: buy nur einen
--   Sparplan bzw. gebuchten Kauf DERSELBEN Position (ISIN, Krypto per Symbol), cash/fee nie einen Sparplan oder Kauf,
--   interest den Zins ohne Textsuche, sell/dividend/tax/corporate/unknown nichts (die Prepare behandelt sie selbst).
--   Gedruckter Auszug = kind NULL = Verhalten wie zuvor.
--   Bank-Import-Modul (Transfers zwischen eigenen Konten, beide Import-Reihenfolgen):
--     0 (Gruppe, ckey 'g:') = schon gebuchter Ad-hoc-Transfer dieses Kontos (von Hand oder aus dem Auszug des
--         Partnerkontos): Gruppe nur aus transfer/fee-Beinen ohne Dauerauftrag/Zins, mit Bein auf einem anderen Konto;
--         Summe der Gruppen-Beine auf DIESEM Konto = Zeilenbetrag, +-5 Tage (Dauerauftrags-Transfers bleiben 't:').
--         Zeile mit transfer_fee (Auszahlung mit Gebuehr): auch Gruppe ohne Gebuehr-Bein = Zeile + Gebuehr (expected <>
--         amount; die Prepare bucht die Gebuehr als eigene Buchung nach, nie in die fremde Gruppe).
--     T = Gegen-IBAN = Kontonummer eines anderen aktiven eigenen Kontos, kein Dauerauftrag getroffen -> neuer Transfer
--         (other_account_id; Buchbarkeit/Abgleich/pending_pair prueft die Prepare).
--         Eine Ein-/Auszahlungs-Zeile ohne Gegen-IBAN (sub_kind deposit|withdrawal, Bondora-Datei) trifft das
--         Verrechnungskonto (settlement_account_id) dieses Kontos. kind interest_line | legacy_return (Datei mit
--         gedrucktem Endstand) trifft nie etwas: die Prepare bucht sie als je eine Summe.
--   Lernen: ein Treffer eines Nicht-Transfer-Dauerauftrags schlaegt die Schluessel der Zeile vor, die die Kette noch
--   nicht hat (learn_mandate / learn_iban; gespeichert erst beim Buchen).
--   RUECKGABE: {matched:[{line_idx, stage, kind (recurring|interest|booked|transfer), recurring_payment_id, due_date,
--   interest_period_end, transaction_id, group_id ('g:'-Treffer), other_account_id (Stufe T), tx_date, line_date, amount,
--   expected, name, side, learn_mandate, learn_iban}],
--   unmatched:[line_idx], unmatched_out, unmatched_in}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_statement_match(p_account_id int, p_cut date, p_period_end date, p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ccy        CHAR(3);
    v_pairs      JSONB;
    v_pair       JSONB;
    v_used_lines INT[]  := '{}';
    v_used_cands TEXT[] := '{}';
    v_matched    JSONB  := '[]'::jsonb;
    v_unmatched  JSONB;
    v_out        NUMERIC;
    v_in         NUMERIC;
BEGIN
    SELECT currency INTO v_ccy FROM finance.accounts WHERE id = p_account_id;

    WITH lines AS (
        SELECT (o.ord)::int AS idx,
               (o.l->>'date')::date AS d,
               round((o.l->>'amount')::numeric, 2) AS amt,
               finance.fn_normalize_account_number(o.l->>'counterparty_iban') AS iban,
               CASE WHEN NULLIF(trim(o.l->>'creditor_id'), '') IS NOT NULL AND NULLIF(trim(o.l->>'mandate_ref'), '') IS NOT NULL
                    THEN upper(regexp_replace(o.l->>'creditor_id', '\s', '', 'g')) || '|'
                         || upper(regexp_replace(o.l->>'mandate_ref', '\s', '', 'g')) END AS mkey,
               lower(COALESCE(o.l->>'counterparty', '') || ' ' || COALESCE(o.l->>'purpose', '')) AS txt,
               NULLIF(o.l->>'kind', '') AS kind, upper(o.l->>'isin') AS isin, upper(o.l->>'symbol') AS symbol,
               NULLIF(o.l->>'sub_kind', '') AS sub_kind, NULLIF(o.l->>'transfer_fee', '')::numeric AS tfee
        FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) WITH ORDINALITY AS o(l, ord)
        WHERE (o.l->>'date')::date > p_cut
    ),
    occ AS (
        SELECT 'r:' || r.id || ':' || o.due_date AS ckey, r.id AS rp_id, o.due_date AS due, r.name,
               CASE WHEN r.account_id = p_account_id THEN 'source' ELSE 'target' END AS side,
               CASE WHEN r.account_id = p_account_id
                    THEN COALESCE(finance.fn_recurring_occurrence_amount(r.id, o.due_date), r.amount)
                    ELSE abs(r.amount) END AS expected,
               CASE WHEN r.account_id = p_account_id THEN r.target_account_id ELSE r.account_id END AS other_acct,
               r.target_account_id,
               sp.id IS NOT NULL AS is_plan, upper(sp.isin) AS sp_isin, upper(sp.symbol) AS sp_symbol
        FROM finance.fn_recurring_due_open(p_cut - 10, p_period_end + 5) o
        JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
        LEFT JOIN finance.savings_plans sp ON sp.recurring_payment_id = finance.fn_recurring_lineage_head(r.id)
        WHERE r.account_id = p_account_id
           OR (r.target_account_id = p_account_id
               AND (SELECT a.currency FROM finance.accounts a WHERE a.id = r.account_id) = v_ccy)
    ),
    pairs AS (
        -- Stufe 0: schon gebuchte Dauerauftrags-/Zinsbuchung dieses Kontos
        SELECT l.idx, '0'::text AS stage, 'booked' AS kind, 't:' || t.id AS ckey, t.recurring_payment_id AS rp_id,
               t.recurring_due_date AS due, t.interest_period_end AS ipe, t.id AS tx_id, l.d, l.amt, t.amount AS expected,
               COALESCE(r.name, t.description) AS name, NULL::text AS side, abs(l.d - t.transaction_date) AS ddiff,
               NULL::text AS learn_mandate, NULL::text AS learn_iban, t.transaction_date AS tx_date,
               NULL::uuid AS group_id, NULL::int AS other_id
        FROM lines l
        JOIN finance.transactions t ON t.account_id = p_account_id
             AND (t.recurring_payment_id IS NOT NULL OR t.interest_period_end IS NOT NULL)
             AND t.transaction_date > p_cut AND t.transaction_date <= p_period_end + 5
             AND t.amount = l.amt AND abs(l.d - t.transaction_date) <= 5
             -- Broker-CSV: ein Wertpapierkauf trifft nur einen gebuchten Kauf derselben Position, Geldzeilen nie einen Kauf
             AND (l.kind IS NULL
                  OR (l.kind IN ('cash', 'fee', 'interest') AND t.category::text <> 'buy')
                  OR (l.kind = 'buy' AND t.category::text = 'buy' AND EXISTS (
                          SELECT 1 FROM finance.depot_holdings h WHERE h.id = t.holding_id
                            AND (upper(h.isin) = l.isin OR (l.isin IS NULL AND upper(h.symbol) = l.symbol)))))
             AND (t.transaction_date <= p_period_end OR NOT EXISTS (
                     SELECT 1 FROM finance.transactions g
                     WHERE (g.id = t.id OR (t.group_id IS NOT NULL AND g.group_id = t.group_id))
                       AND finance.fn_reconciled_reason(g.account_id, l.d) IS NOT NULL))
        LEFT JOIN finance.recurring_payments r ON r.id = t.recurring_payment_id
        UNION ALL
        -- Stufe A/B: offene Dauerauftrags-Vorkommen
        SELECT l.idx, x.stage, 'recurring', o.ckey, o.rp_id, o.due, NULL::date, NULL::int, l.d, l.amt, o.expected,
               o.name, o.side, abs(l.d - o.due),
               CASE WHEN o.target_account_id IS NULL AND l.mkey IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM finance.recurring_payment_keys k
                        WHERE k.key_type = 'sepa_mandate' AND k.key_value = l.mkey) THEN l.mkey END,
               CASE WHEN o.target_account_id IS NULL AND l.iban IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM finance.recurring_payment_keys k
                        WHERE k.key_type = 'counterparty_iban' AND k.key_value = l.iban
                          AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(o.rp_id))) THEN l.iban END,
               NULL::date, NULL::uuid, NULL::int
        FROM lines l
        CROSS JOIN occ o
        CROSS JOIN LATERAL (
            SELECT CASE
                WHEN abs(l.d - o.due) <= 10
                     AND abs(l.amt) BETWEEN abs(o.expected) * 0.5 AND abs(o.expected) * 1.5
                     AND ( (l.mkey IS NOT NULL AND EXISTS (
                               SELECT 1 FROM finance.recurring_payment_keys k
                               WHERE k.key_type = 'sepa_mandate' AND k.key_value = l.mkey
                                 AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(o.rp_id))))
                        OR (l.iban IS NOT NULL AND EXISTS (
                               SELECT 1 FROM finance.recurring_payment_keys k
                               WHERE k.key_type = 'counterparty_iban' AND k.key_value = l.iban
                                 AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(o.rp_id))))
                        OR (l.iban IS NOT NULL AND o.other_acct IS NOT NULL AND l.iban =
                               (SELECT a.account_number FROM finance.accounts a WHERE a.id = o.other_acct)) )
                THEN 'A'
                WHEN (l.d - o.due) BETWEEN -5 AND 10
                     AND ( abs(l.amt - o.expected) <= 0.005
                        OR ( abs(l.amt - o.expected) <= GREATEST(abs(o.expected) * 0.05, 2)
                             AND EXISTS (SELECT 1 FROM regexp_split_to_table(lower(o.name), '[\s,.;:/()_+&-]+') tok
                                         WHERE length(tok) >= 4 AND position(tok IN l.txt) > 0) ) )
                THEN 'B'
            END AS stage
        ) x
        WHERE x.stage IS NOT NULL AND sign(l.amt) = sign(o.expected)
          -- Broker-CSV: Kauf-Zeile nur gegen einen Sparplan DERSELBEN Position, Geldzeile nie gegen einen Sparplan,
          -- Verkauf/Dividende/Steuer/unbekannt nie gegen einen Dauerauftrag (gedruckter Auszug: kind NULL, wie bisher)
          AND (l.kind IS NULL
               OR (l.kind = 'buy' AND o.is_plan AND (o.sp_isin = l.isin OR (o.sp_isin IS NULL AND l.isin IS NULL AND o.sp_symbol = l.symbol)))
               OR (l.kind IN ('cash', 'fee') AND NOT o.is_plan))
        UNION ALL
        -- Zins-Vorkommen (Stufe B, nur Zeilen mit "zins")
        SELECT l.idx, 'B'::text, 'interest', 'i:' || i.period_end, NULL::int, NULL::date, i.period_end, NULL::int, l.d, l.amt,
               finance.fn_interest_amount_due(p_account_id, i.period_end), 'interest', NULL, abs(l.d - i.value_date),
               NULL, NULL, NULL::date, NULL::uuid, NULL::int
        FROM lines l
        JOIN finance.fn_interest_due_open(p_period_end + 5) i ON i.account_id = p_account_id
        WHERE l.amt > 0 AND (l.kind = 'interest' OR (l.kind IS NULL AND l.txt LIKE '%zins%'))
          AND (l.d - i.value_date) BETWEEN -5 AND 10
          AND abs(l.amt - finance.fn_interest_amount_due(p_account_id, i.period_end))
              <= GREATEST(finance.fn_interest_amount_due(p_account_id, i.period_end) * 0.05, 0.10)
        UNION ALL
        -- Stufe 0 (Gruppe): schon gebuchter Ad-hoc-Transfer (von Hand oder aus dem Auszug des Partnerkontos)
        SELECT l.idx, '0'::text, 'booked', 'g:' || g.group_id, NULL::int, NULL::date, NULL::date, g.tx_id, l.d, l.amt, g.amt,
               g.name, NULL::text, abs(l.d - g.tx_date), NULL::text, NULL::text, g.tx_date, g.group_id, NULL::int
        FROM lines l
        JOIN (SELECT t.group_id, sum(t.amount) AS amt, min(t.id) AS tx_id, min(t.transaction_date) AS tx_date,
                     min(t.description) AS name, bool_or(t.category::text = 'fee') AS has_fee
              FROM finance.transactions t
              WHERE t.account_id = p_account_id AND t.group_id IS NOT NULL
                AND t.transaction_date > p_cut AND t.transaction_date <= p_period_end + 5
              GROUP BY t.group_id) g
          -- Auszahlung mit Gebuehr (Profil), deren Transfer das Partnerkonto ohne Gebuehr gebucht hat: Gruppe = Zeile +
          -- Gebuehr -> expected <> amount, apply bucht die Gebuehr als eigene Buchung nach
          ON (g.amt = l.amt OR (l.tfee > 0 AND NOT g.has_fee AND g.amt = l.amt + l.tfee)) AND abs(l.d - g.tx_date) <= 5
        WHERE (l.kind IS NULL OR l.kind IN ('cash', 'fee'))
          AND NOT EXISTS (SELECT 1 FROM finance.transactions x WHERE x.group_id = g.group_id
                          AND (x.category::text NOT IN ('transfer', 'fee') OR x.recurring_payment_id IS NOT NULL
                               OR x.interest_period_end IS NOT NULL))
          AND EXISTS (SELECT 1 FROM finance.transactions x WHERE x.group_id = g.group_id AND x.account_id <> p_account_id)
        UNION ALL
        -- Stufe T: Gegen-IBAN = Kontonummer eines anderen aktiven eigenen Kontos -> neuer Transfer
        SELECT l.idx, 'T'::text, 'transfer', 'x:' || l.idx, NULL::int, NULL::date, NULL::date, NULL::int, l.d, l.amt, l.amt,
               a.name, CASE WHEN l.amt < 0 THEN 'source' ELSE 'target' END, 0, NULL::text, NULL::text, NULL::date,
               NULL::uuid, a.id
        FROM lines l
        JOIN finance.accounts a ON a.status = 'active' AND a.id <> p_account_id
             AND (a.account_number = l.iban
                  -- Ein-/Auszahlung ohne Gegen-IBAN (Bondora-Datei): das Verrechnungskonto dieses Kontos
                  OR (l.iban IS NULL AND l.sub_kind IN ('deposit', 'withdrawal')
                      AND a.id = (SELECT s.settlement_account_id FROM finance.accounts s WHERE s.id = p_account_id)))
        WHERE l.amt <> 0 AND (l.kind IS NULL OR l.kind = 'cash')
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'line_idx', p.idx, 'stage', p.stage::text, 'kind', p.kind, 'ckey', p.ckey,
               'recurring_payment_id', p.rp_id, 'due_date', p.due, 'interest_period_end', p.ipe,
               'transaction_id', p.tx_id, 'group_id', p.group_id, 'other_account_id', p.other_id,
               'tx_date', p.tx_date, 'line_date', p.d, 'amount', p.amt, 'expected', round(p.expected, 2),
               'name', p.name, 'side', p.side, 'learn_mandate', p.learn_mandate, 'learn_iban', p.learn_iban)
             ORDER BY p.stage::text, abs(p.amt - p.expected), p.ddiff, p.idx, p.ckey), '[]'::jsonb)
    INTO v_pairs
    FROM (SELECT idx, stage::text AS stage, kind, ckey, rp_id, due, ipe, tx_id, d, amt, expected, name, side, ddiff,
                 learn_mandate, learn_iban, tx_date, group_id, other_id FROM pairs) p;

    FOR v_pair IN SELECT e FROM jsonb_array_elements(v_pairs) e LOOP
        CONTINUE WHEN (v_pair->>'line_idx')::int = ANY(v_used_lines) OR (v_pair->>'ckey') = ANY(v_used_cands);
        v_used_lines := v_used_lines || (v_pair->>'line_idx')::int;
        v_used_cands := v_used_cands || (v_pair->>'ckey');
        v_matched := v_matched || (v_pair - 'ckey');
    END LOOP;

    SELECT COALESCE(jsonb_agg((o.ord)::int ORDER BY o.ord), '[]'::jsonb),
           COALESCE(sum(round((o.l->>'amount')::numeric, 2)) FILTER (WHERE (o.l->>'amount')::numeric < 0), 0),
           COALESCE(sum(round((o.l->>'amount')::numeric, 2)) FILTER (WHERE (o.l->>'amount')::numeric > 0), 0)
    INTO v_unmatched, v_out, v_in
    FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) WITH ORDINALITY AS o(l, ord)
    WHERE (o.l->>'date')::date > p_cut AND NOT ((o.ord)::int = ANY(v_used_lines));

    RETURN jsonb_build_object('matched', v_matched, 'unmatched', v_unmatched,
                              'unmatched_out', v_out, 'unmatched_in', v_in);
END;
$$;
