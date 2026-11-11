-- ============================================================
-- fn_get_recurring_suggestions (READ, STABLE) -- wiederkehrende Zahlungen aus einem Bank-Export erkennen ("Import zuerst")
--   Die Datei kommt ueber fn_bank_export_load (Leser + Konto-Waechter + Sub-Konto-Waechter; kein Startpunkt noetig, es
--   wird nichts gebucht). Rechnet alles in der DB (das LLM uebernimmt die Werte nur in die Write-Tools,
--   tool_create_recurring_payment / tool_create_recurring_transfer mit Karte). Muster: Actual "Find schedules",
--   Plaid /transactions/recurring/get, Sure RecurringTransaction::Identifier (Belege im Plan der Session 3d).
--   Erkennung (Schluessel, Betrags-Cluster, Rhythmus, Reife, Startdatum, Bekannt-Filter, Art) allein in
--   fn_get_recurring_candidates mode export (eine Adresse mit dem Kontoauszug).
--   Spanne erste-letzte Buchung < 75 Tage (~3 Monate) -> keine Vorschlaege, hint export_too_short (Plaid empfiehlt 180
--   Tage); Dateiende aelter als 45 Tage -> hint export_stale.
--   plpgsql (late-bound): fn_get_recurring_candidates liegt alphabetisch davor, fn_bank_export_load bleibt late-bound.
--   Eingabe jsonb: {account_name (optional), table:{rows}, with_dates (optional, fn_import_stage_recurring: Vorschlaege behalten
--   dates + from/to_account_id, Ergebnis traegt account_id)}. Fehlertexte nennen nie Zellinhalte.
--   RUECKGABE: {ok:true, account_name, period_first, period_last, span_days, hint?, suggestions:[{name (Schreibweise
--   der juengsten Zeile), kind, direction, counterparty_iban?, from_account?, to_account?, amount (juengster Betrag,
--   positiv), average_amount, amount_varies, schedule_unit, schedule_interval, schedule_day_of_month (NULL ausser
--   month), first_payment_date, occurrences, first_date, last_date}] (nach Monatsbetrag absteigend),
--   known_elsewhere:[{name, account_name}]} | Codes von fn_bank_export_load.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_recurring_suggestions(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_today  DATE := core.fn_today();
    v_load   JSONB;
    v_acct   finance.accounts%ROWTYPE;
    v_first  DATE;
    v_last   DATE;
    v_hint   TEXT;
    v_cand   JSONB;
    v_keep   BOOLEAN := COALESCE((p->>'with_dates')::boolean, false);
BEGIN
    v_load := finance.fn_bank_export_load(p);
    IF (v_load->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_load;
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = (v_load->>'account_id')::int;
    SELECT min((r->>'date')::date), max((r->>'date')::date) INTO v_first, v_last
    FROM jsonb_array_elements(v_load->'rows') r;
    -- Spanne zwischen erster und letzter Buchung: ein echter 3-Monats-Export (1.8.-31.10.) hat Buchungen ab ~3.8. bis
    -- ~28.10. = 86 Tage -> Schwelle 75 Tage, sonst fordert der Agent im Kreis "mindestens 3 Monate"
    IF v_first IS NULL OR v_last - v_first < 75 THEN
        RETURN jsonb_build_object('ok', true, 'account_name', v_acct.name, 'period_first', v_first, 'period_last', v_last,
            'span_days', COALESCE(v_last - v_first, 0), 'hint', 'export_too_short',
            'reason', 'The export covers less than 3 months - ask for an export of the last 6 months (at least 3).',
            'suggestions', '[]'::jsonb, 'known_elsewhere', '[]'::jsonb);
    END IF;
    IF v_last < v_today - 45 THEN
        v_hint := 'export_stale';
    END IF;
    v_cand := finance.fn_get_recurring_candidates(jsonb_build_object('account_id', v_acct.id, 'mode', 'export',
                  'period_last', v_last, 'lines', v_load->'rows'));
    RETURN jsonb_strip_nulls(jsonb_build_object('ok', true, 'account_name', v_acct.name, 'period_first', v_first,
               'period_last', v_last, 'span_days', v_last - v_first, 'hint', v_hint,
               'account_id', CASE WHEN v_keep THEN v_acct.id END))
        || jsonb_build_object(
               'suggestions', COALESCE((SELECT jsonb_agg(CASE WHEN v_keep THEN s ELSE s - 'dates' - 'from_account_id' - 'to_account_id' END ORDER BY o)
                                        FROM jsonb_array_elements(v_cand->'suggestions') WITH ORDINALITY x(s, o)), '[]'::jsonb),
               'known_elsewhere', v_cand->'known_elsewhere');
END;
$$;
