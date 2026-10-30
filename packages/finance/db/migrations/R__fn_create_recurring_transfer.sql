-- ============================================================
-- fn_create_recurring_transfer (ATOMIC WRITE)
--   Legt einen INTERNEN wiederkehrenden Transfer zwischen zwei eigenen Konten an (z. B. Dauerauftrag
--   200 EUR/Monat Owner-Konto -> Kind-Depot-Cash). NICHT fuer Einnahmen/Ausgaben nach aussen (->
--   fn_create_recurring_payment) und nicht fuer Sparplaene (-> fn_create_savings_plan). Die Zeile ist
--   per target_account_id als Transfer markiert -> strukturell cashflow-neutral (zaehlt NICHT als
--   Haushalts-Ausgabe/Sparquote). Buchung je Faelligkeit zwei-beinig via fn_book_recurring_transfer
--   (ueber den bestehenden Recurring-Scheduler).
--   amount wird Quell-seitig NEGATIV gespeichert (Geld verlaesst die Quelle); gebucht wird abs(amount).
--   INSERT laeuft ueber den gemeinsamen Helper fn_add_recurring_payment (single source) + Folge-UPDATE
--   fuer target_account_id (eine Transaktion, atomar). Der No-Self-Transfer-CHECK ist der Backstop.
--   Eingabe jsonb: name, from_account_id (n8n-resolved), to_account_id (n8n-resolved), amount (positiv),
--   schedule_interval (opt, default 1), schedule_unit, schedule_day_of_month (opt), first_payment_date,
--   valid_from (opt, default first_payment_date), valid_to (opt; LETZTER gueltiger Tag, inklusiv -> gespeichert
--   wird der Folgetag, Konvention [valid_from, valid_to) exklusiv), notes (opt).
--   valid_from der Zahlung = spaetester Eroeffnungssaldo-Stichtag beider Konten (fn_recurring_valid_from).
--   RUECKGABE: Erfolg -> {ok:true, recurring_payment_id, monthly_equivalent, card_lines} + optional savings_funding
--   (fn_savings_funding_fold, Bericht ohne Frage: Spar-Deckung von Quelle UND Ziel nach dem Write, je Deckungs-Konto
--   eine Kartenzeile „Danach ..."). Korrigierbar (amount<=0 / Quelle==Ziel) -> {ok:false, reason} OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_recurring_transfer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_from     INT      := (p->>'from_account_id')::int;
    v_to       INT      := (p->>'to_account_id')::int;
    v_amount   NUMERIC  := (p->>'amount')::numeric;
    v_interval SMALLINT := COALESCE(NULLIF(p->>'schedule_interval','')::smallint, 1);
    v_unit     finance.schedule_unit := (p->>'schedule_unit')::finance.schedule_unit;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month','')::smallint;
    v_first    DATE;
    v_from_dt  DATE;
    v_to_dt    DATE;
    v_rp_id    INT;
    v_me       NUMERIC;
    v_nc       JSONB;
    v_dates    JSONB;
    v_fold     JSONB;
BEGIN
    -- relative Datumsangaben ("in 2 weeks") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['first_payment_date', 'valid_from', 'valid_to']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_first   := (p->>'first_payment_date')::date;
    v_from_dt := COALESCE(NULLIF(p->>'valid_from','')::date, (p->>'first_payment_date')::date);
    v_to_dt   := NULLIF(p->>'valid_to','')::date + 1;   -- inklusiver letzter Tag -> exklusives Ende
    -- DB-ist-das-Gesetz S6: laufende freistehende Zahlung gleichen Namens -> ok:false; Entitaets-Zahlung -> Karten-Hinweis
    v_nc := finance.fn_recurring_name_check(p->>'name');
    IF (v_nc->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_nc;
    END IF;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Transfer amount must be a positive number, got ' || COALESCE(v_amount::text,'null') || '.');
    END IF;
    IF v_from = v_to THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Source and destination account are the same — a transfer needs two different accounts.');
    END IF;

    -- INSERT via gemeinsamen Helper (single source), amount Quell-seitig negativ; target via Folge-UPDATE.
    v_rp_id := finance.fn_add_recurring_payment(
        v_from, -v_amount, p->>'name',
        v_interval, v_unit, v_dom, v_first,
        GREATEST(finance.fn_recurring_valid_from(v_from, v_from_dt), finance.fn_recurring_valid_from(v_to, v_from_dt)),
        v_to_dt, NULL, NULLIF(p->>'notes',''));

    UPDATE finance.recurring_payments SET target_account_id = v_to WHERE id = v_rp_id;

    SELECT monthly_equivalent INTO v_me FROM finance.recurring_payments WHERE id = v_rp_id;

    -- Spar-Deckung beider Konten nach dem Write (Zubringer fuellt das Ziel, ein Abzug kann die Quelle leeren);
    -- „gedeckt" berichtet nur das Ziel (Geldeingang), die Quelle nur bei einer Luecke
    v_fold := finance.fn_savings_funding_fold(ARRAY[v_from, v_to], false, false, ARRAY[v_to]);

    RETURN finance.fn_merge_fold(
        jsonb_build_object('ok', true, 'recurring_payment_id', v_rp_id, 'monthly_equivalent', v_me,
                           'card_lines', v_nc->'card_lines', 'effective', v_dates->'resolved'),
        v_fold);
END;
$$;
