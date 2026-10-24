-- ============================================================
-- fn_create_recurring_payment (ATOMIC WRITE)
--   Legt eine standalone wiederkehrende Einnahme/Ausgabe an (Gehalt, Miete, Abo, Rentenzahlung,
--   Mitgliedschaft) — NICHT fuer Versicherung/Kredit/Sparrate (eigene Tools). Vorzeichen aus
--   direction: income -> +amount, expense -> -amount. INSERT via gemeinsamen Helper
--   fn_add_recurring_payment. Eingabe jsonb: name, account_id (n8n-resolved), direction
--   ('income'|'expense'), amount (positiv), schedule_interval (opt, default 1), schedule_unit,
--   schedule_day_of_month (opt), first_payment_date, valid_from (opt, default first_payment_date),
--   valid_to (opt; LETZTER gueltiger Tag, inklusiv wie vom Nutzer genannt -> gespeichert wird der Folgetag,
--   Speicher-Konvention [valid_from, valid_to) exklusiv), notes (opt).
--   valid_from der Zahlung = fn_recurring_valid_from (fruehestens der Eroeffnungssaldo-Stichtag des Kontos).
--   RUECKGABE: Erfolg -> {ok:true, recurring_payment_id, monthly_equivalent}. Korrigierbar
--   (direction/amount, schedule_unit unbekannt, Konto nicht buchbar [Depot/Kredit: die Faelligkeit bliebe
--   sonst ewig offen]) -> {ok:false, reason} OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_recurring_payment(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_account  INT      := (p->>'account_id')::int;
    v_dir      TEXT     := p->>'direction';
    v_amount   NUMERIC  := (p->>'amount')::numeric;
    v_interval SMALLINT := COALESCE(NULLIF(p->>'schedule_interval','')::smallint, 1);
    v_unit     finance.schedule_unit;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_reason   TEXT     := COALESCE(finance.fn_enum_reason('finance.schedule_unit'::regtype, p->>'schedule_unit', 'schedule_unit'),
                                    finance.fn_bookable_account_reason((p->>'account_id')::int));
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month','')::smallint;
    v_first    DATE     := (p->>'first_payment_date')::date;
    v_from     DATE     := COALESCE(NULLIF(p->>'valid_from','')::date, (p->>'first_payment_date')::date);
    v_to       DATE     := NULLIF(p->>'valid_to','')::date + 1;   -- inklusiver letzter Tag -> exklusives Ende
    v_signed   NUMERIC;
    v_rp_id    INT;
    v_me       NUMERIC;
    v_cf       JSONB := '{}'::jsonb;   -- Phase Notify: gefaltete cashflow_coverage-Note (nur bei Latch-Flanke)
    v_nc       JSONB;
BEGIN
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- DB-ist-das-Gesetz S6: laufende freistehende Zahlung gleichen Namens -> ok:false; Entitaets-Zahlung -> Karten-Hinweis
    v_nc := finance.fn_recurring_name_check(p->>'name');
    IF (v_nc->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_nc;
    END IF;
    v_unit := (p->>'schedule_unit')::finance.schedule_unit;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Korrigierbare Input-Pruefungen -> {ok:false}.
    IF v_dir NOT IN ('income','expense') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Direction must be income or expense, got ' || COALESCE(v_dir,'null') || '.');
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Amount must be a positive number, got ' || COALESCE(v_amount::text,'null') || '.');
    END IF;

    v_signed := CASE v_dir WHEN 'expense' THEN -v_amount ELSE v_amount END;

    v_rp_id := finance.fn_add_recurring_payment(
        v_account, v_signed, p->>'name',
        v_interval, v_unit, v_dom, v_first, finance.fn_recurring_valid_from(v_account, v_from), v_to, NULL, NULLIF(p->>'notes',''));

    SELECT monthly_equivalent INTO v_me FROM finance.recurring_payments WHERE id = v_rp_id;

    -- Phase L WS-3: Cashflow-Sofort-Hinweis (Event-Fold). Post-State NACH dem INSERT: die soeben angelegte Zahlung
    -- ist (sofern aktiv + heute gueltig) in der Live-View. Audit Paket 3: der eine Fold-Helfer (Pflichtausgaben >
    -- Einnahmen, gelatcht, Re-Arm bei Erholung) — geteilt mit fn_set_recurring_payment.
    v_cf := finance.fn_cashflow_coverage_fold();

    RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_rp_id, 'monthly_equivalent', v_me,
                              'card_lines', v_nc->'card_lines') || v_cf;
END;
$$;
