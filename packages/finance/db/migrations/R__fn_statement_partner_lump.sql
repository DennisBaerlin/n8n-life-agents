-- ============================================================
-- fn_statement_partner_lump (READ, STABLE) -- steckt eine eigene Ueberweisung schon im Rest des Gegenkontos? (Monats-Check)
--   Befund KW 45: der zuerst eingelesene Auszug kennt das andere Konto noch nicht und bucht die Zeile in seinen Rest; der
--   spaetere Auszug des anderen Kontos erkennt den Transfer und buchte ihn ein zweites Mal. Einzelzeilen sind nicht
--   gespeichert (Owner-Vorgabe), die Suche arbeitet nur auf den Aggregaten des Auszugs und seiner Rest-Buchung.
--   Eingabe: p_other = Gegenkonto, p_line_date = Zeilendatum, p_leg = erwartetes Bein auf dem Gegenkonto (signiert),
--   p_used = in dieser Vorschau schon Verrechnetes {"<statement_id>":{"open":n,"other":n}} (je Auszug + Quelle).
--   Fenster je Auszug: Bein positiv (Zeile geht hier ab, kommt dort spaeter an) [period_start-5, period_end+1], Bein negativ
--   (Zeile kommt hier an, ging dort frueher ab) [period_start-1, period_end+5]. Eine Ueberweisung nach dem Auszugsende bleibt
--   so eine normale Ueberweisung, auch wenn dort offene Betraege liegen.
--   Groessen: open = unmatched_in (Bein > 0) bzw. unmatched_out (Bein < 0); other = Rest - unmatched_in - unmatched_out
--   - export_gap (blockierte Zeilen, Fremdbuchungen; anders als das Rueckgabefeld rest_other nie Vormerkungen).
--   exact: Rest-Buchung vorhanden UND (open = Bein ODER other = Bein), source open|other. Der Netto-Rest allein ist nie
--   exact: +900/-800 ergibt 100, ohne dass es eine solche Zeile gibt. possible: Zeile <= letzter Abgleich des Gegenkontos und
--   |Bein| <= |open|; oder other mit passendem Vorzeichen und |Bein| <= |other|; oder Saldo-Abgleich per Chat
--   (source chat, ohne Auszug: kein Zeitraum, nicht ruecknehmbar, daher nie exact) mit passendem Vorzeichen, |Bein| <= |Buchung|,
--   Stichtag-5 <= Zeile <= Stichtag. Bleibt das Vorzeichen-/Betrags-Bild offen -> NULL (Verhalten wie ohne Fund).
--   Auswahl: der Auszug, dessen Zeitraum die Zeile enthaelt, vor anderen; zwei exact ausserhalb -> possible (nie raten).
--   offset_date = Datum des Gegenbeins: im bestaetigten Zeitraum des Auszugs, nie vor seinem Vor-Abgleich bzw. Startsaldo.
--   Bekannte Grenze: heben sich blockierte Zeilen und Fremdbuchungen in other genau auf, sieht die Suche sie nicht; der
--   naechste Auszug des Kontos gleicht das ueber den Rest aus.
--   RUECKGABE: {match, source, statement_id, lump_tx_id, lump_amount, offset_date} | NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_statement_partner_lump(p_other int, p_line_date date, p_leg numeric, p_used jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct     finance.accounts%ROWTYPE;
    v_recon    BOOLEAN;
    v_s        RECORD;
    v_open     NUMERIC;
    v_other    NUMERIC;
    v_hit      JSONB;
    v_exact    JSONB := '[]'::jsonb;
    v_possible JSONB;
BEGIN
    IF COALESCE(p_leg, 0) = 0 THEN RETURN NULL; END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = p_other;
    v_recon := finance.fn_reconciled_reason(p_other, p_line_date) IS NOT NULL;

    FOR v_s IN
        SELECT s.id, s.period_start, s.period_end, s.unmatched_in, s.unmatched_out, s.export_gap, s.prev_last_reconciled_at,
               p_line_date BETWEEN s.period_start AND s.period_end AS inside, l.id AS lump_id, l.amount AS lump
        FROM finance.bank_statements s
        LEFT JOIN LATERAL (SELECT t.id, t.amount FROM finance.transactions t
                           WHERE t.bank_statement_id = s.id AND t.account_id = p_other
                             AND t.category::text = 'reconciliation' AND t.transaction_date = s.period_end
                           ORDER BY t.id DESC LIMIT 1) l ON true
        WHERE s.account_id = p_other
          AND p_line_date BETWEEN s.period_start - CASE WHEN p_leg > 0 THEN 5 ELSE 1 END
                              AND s.period_end   + CASE WHEN p_leg > 0 THEN 1 ELSE 5 END
        ORDER BY (p_line_date BETWEEN s.period_start AND s.period_end) DESC, s.period_end DESC
    LOOP
        v_open  := CASE WHEN p_leg > 0 THEN v_s.unmatched_in ELSE v_s.unmatched_out END
                   - COALESCE((p_used->(v_s.id::text)->>'open')::numeric, 0);
        v_other := COALESCE(v_s.lump, 0) - v_s.unmatched_in - v_s.unmatched_out - COALESCE(v_s.export_gap, 0)
                   - COALESCE((p_used->(v_s.id::text)->>'other')::numeric, 0);
        v_hit := jsonb_build_object('statement_id', v_s.id, 'lump_tx_id', v_s.lump_id, 'lump_amount', v_s.lump,
                     'offset_date', LEAST(GREATEST(p_line_date, v_s.period_start, v_s.prev_last_reconciled_at + 1,
                                                   v_acct.opening_balance_date + 1), v_s.period_end));
        IF v_s.lump_id IS NOT NULL AND (v_open = p_leg OR v_other = p_leg) THEN
            v_exact := v_exact || (v_hit || jsonb_build_object('match', 'exact', 'inside', v_s.inside,
                           'source', CASE WHEN v_open = p_leg THEN 'open' ELSE 'other' END));
        ELSIF v_possible IS NULL
              AND ((v_recon AND sign(v_open) = sign(p_leg) AND abs(p_leg) <= abs(v_open))
                   OR (sign(v_other) = sign(p_leg) AND abs(p_leg) <= abs(v_other))) THEN
            v_possible := v_hit || jsonb_build_object('match', 'possible',
                              'source', CASE WHEN sign(v_other) = sign(p_leg) AND abs(p_leg) <= abs(v_other) THEN 'other' ELSE 'open' END);
        END IF;
    END LOOP;

    IF jsonb_array_length(v_exact) = 1 OR (v_exact->0->>'inside')::boolean THEN
        RETURN (v_exact->0) - 'inside';
    ELSIF jsonb_array_length(v_exact) > 1 THEN
        RETURN (v_exact->0) - 'inside' || jsonb_build_object('match', 'possible');
    END IF;
    IF v_possible IS NOT NULL THEN RETURN v_possible; END IF;

    SELECT jsonb_build_object('match', 'possible', 'source', 'chat', 'lump_tx_id', t.id, 'lump_amount', t.amount) INTO v_possible
    FROM finance.transactions t
    WHERE t.account_id = p_other AND t.category::text = 'reconciliation' AND t.bank_statement_id IS NULL
      AND sign(t.amount) = sign(p_leg) AND abs(p_leg) <= abs(t.amount)
      AND p_line_date BETWEEN t.transaction_date - 5 AND t.transaction_date
    ORDER BY t.transaction_date DESC, t.id DESC LIMIT 1;
    RETURN v_possible;
END;
$$;
