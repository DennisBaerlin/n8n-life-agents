-- ============================================================
-- fn_create_savings_plan (ATOMIC WRITE)
--   Legt in EINER Transaktion an: (1) recurring_payment auf dem Verrechnungskonto
--   des Depots (monatliche Cash-Abbuchung), (2) Sparplan-Eintrag mit FK-Link.
--   Invariante: Depot-Typ und ISIN-Praesenz muessen passen (stocks_depot=ISIN erwartet,
--   crypto_depot=ISIN verboten). Uniqueness via UNIQUE INDEX (lower(name)).
--   Eingabe jsonb: name, depot_name, isin (opt), symbol (opt bei ISIN -- fn_holding_symbol), security_name, amount,
--   schedule_interval, schedule_unit, schedule_day_of_month (opt), first_payment_date,
--   notes (opt), beneficiary_person_id (opt, Slug; leer = Inhaber des Depots, fn_default_beneficiary;
--     Depot ohne Inhaber -> NULL=Haushalt),
--   depot_execution_days (opt -- rohe Nutzer-Antwort nach needs_calendar: Monatstage oder 'none'),
--   asset_class (opt -- Phase L WS-6: Allokations-Block-key, lowercase snake; an jede Ausfuehrung vererbt;
--     Format-Verstoss -> {ok:false}).
--   RHYTHMUS: der genannte Rhythmus (z. B. week/1) wird ueber den Depot-Kalender abgeleitet
--     (fn_resolve_plan_schedule: Broker mit festen Monatstagen -> month + schedule_days_of_month); ein neu
--     gelernter/vorbelegter Kalender wird im selben Write am Depot gespeichert (accounts.plan_execution_days).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, savings_plan_id, recurring_payment_id, card_lines,
--   beneficiary_person_id, beneficiary_name (ueber core.fn_household_persons, D10), monthly_amount (Betrag je Monat,
--   positiv, aus der GENERATED-Spalte), schedule_unit/schedule_interval/schedule_day_of_month (gespeichert),
--   schedule_days ("2, 9, 16, 23" oder null), calendar_learned (nur wenn der Depot-Kalender neu gesetzt wurde),
--   effective {beneficiary_person_id}} + optional savings_squeeze (fn_savings_squeeze_fold; erster Abbuchungstag in
--   der Zukunft -> erst der Cron).
--   Korrigierbar (Depot nicht gefunden, Typ-Mismatch, Duplikat, amount<=0, asset_class-Format, Rhythmus passt nicht
--   zum Depot-Kalender (+ next_possible_date), Kalender unbekannt (needs_calendar)) -> {ok:false, reason} OHNE Write
--   (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_savings_plan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_depot_name  TEXT              := p->>'depot_name';
    v_isin        TEXT              := NULLIF(p->>'isin', '');
    v_symbol      TEXT              := finance.fn_holding_symbol(p->>'symbol', p->>'isin');  -- ohne Ticker = ISIN (wie fn_book_stock_buy)
    v_sec_name    TEXT              := p->>'security_name';
    v_amount      NUMERIC           := (p->>'amount')::numeric;
    v_interval    SMALLINT          := COALESCE(NULLIF(p->>'schedule_interval', '')::smallint, 1);
    v_unit        finance.schedule_unit := (COALESCE(NULLIF(p->>'schedule_unit', ''), 'month'))::finance.schedule_unit;
    v_dom         SMALLINT          := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_first       DATE;
    v_asset_cls   TEXT              := NULLIF(p->>'asset_class', '');  -- Phase L WS-6: Allokations-Block-key (vererbt)
    v_depot_id    INT;
    v_settle_id   INT;
    v_depot_type  finance.account_type;
    v_plan_id     INT;
    v_rp_id       INT;
    v_sim         TEXT;
    v_sched       JSONB;
    v_days        SMALLINT[];
    v_benef       TEXT;
    v_monthly     NUMERIC;
    v_dates       JSONB;
BEGIN
    -- relative Datumsangabe ("next monday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['first_payment_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_first := (p->>'first_payment_date')::date;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Input-Pruefungen -> {ok:false}
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Amount must be a positive number, got ' || COALESCE(v_amount::text, 'null') || '.');
    END IF;
    IF v_symbol IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'A savings plan needs a ticker symbol or an ISIN (crypto: the coin symbol).');
    END IF;
    -- WS-6: das Anlageklasse-Etikett muss das Block-key-Format treffen (lowercase snake) -> {ok:false} statt
    -- hartem CHECK-RAISE/Owner-Alert (das LLM nennt das Label, es ist nutzer-korrigierbar; mirror fn_book_stock_buy).
    IF v_asset_cls IS NOT NULL AND v_asset_cls !~ '^[a-z0-9_]+$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'asset_class tag must be lowercase letters/digits/underscore (e.g. sp500), got: ' || v_asset_cls);
    END IF;

    -- Depot aufloesen (exakter Name-Match, aktive Konten)
    SELECT a.id, a.account_type, a.settlement_account_id
    INTO v_depot_id, v_depot_type, v_settle_id
    FROM finance.accounts a
    WHERE a.name = v_depot_name AND a.status = 'active'
    LIMIT 1;

    IF v_depot_id IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Depot "' || v_depot_name || '" not found or not active. '
                   || 'Please check the depot name.');
    END IF;
    IF v_depot_type NOT IN ('stocks_depot', 'crypto_depot') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Account "' || v_depot_name || '" is a ' || v_depot_type
                   || ', not a depot. Savings plans require a stocks_depot or crypto_depot.',
            'account_type', v_depot_type);
    END IF;
    IF v_settle_id IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Depot "' || v_depot_name || '" has no settlement account. '
                   || 'Please link a settlement account first.');
    END IF;

    -- Depot-Typ vs. ISIN-Praesenz (gleiche Regel wie fn_book_stock_buy)
    IF v_isin IS NOT NULL AND v_depot_type <> 'stocks_depot' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Depot type mismatch: an ISIN-based savings plan requires a stocks_depot, '
                   || 'but "' || v_depot_name || '" is a ' || v_depot_type || '.',
            'depot_type', v_depot_type);
    END IF;
    IF v_isin IS NULL AND v_depot_type <> 'crypto_depot' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Depot type mismatch: a savings plan without ISIN (crypto) requires a crypto_depot, '
                   || 'but "' || v_depot_name || '" is a ' || v_depot_type || '.',
            'depot_type', v_depot_type);
    END IF;

    -- Rhythmus ueber den Depot-Kalender ableiten (Broker mit festen Monatstagen; unbekannt -> needs_calendar)
    v_sched := finance.fn_resolve_plan_schedule(v_depot_id, v_unit, v_interval, v_dom, v_first,
                                                NULLIF(p->>'depot_execution_days', ''));
    IF (v_sched->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_sched;
    END IF;
    v_unit     := (v_sched->>'schedule_unit')::finance.schedule_unit;
    v_interval := (v_sched->>'schedule_interval')::smallint;
    v_dom      := (v_sched->>'schedule_day_of_month')::smallint;
    v_days     := finance.fn_jsonb_smallint_array(v_sched->'schedule_days_of_month');
    v_benef    := finance.fn_default_beneficiary(p->>'beneficiary_person_id', v_depot_id);

    -- Uniqueness-Guard (UNIQUE INDEX ist Backstop; hier freundliche Meldung)
    IF EXISTS (
        SELECT 1 FROM finance.savings_plans
        WHERE lower(name) = lower(p->>'name')
    ) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A savings plan named "' || (p->>'name') || '" already exists. '
                   || 'Choose a different name or check if it is already set up.');
    END IF;

    -- 1. Recurring Payment auf Verrechnungskonto (negativ = Ausgabe)
    v_rp_id := finance.fn_add_recurring_payment(
        v_settle_id,
        -v_amount,
        'Sparplan ' || (p->>'name'),
        v_interval,
        v_unit,
        v_dom,
        v_first,
        finance.fn_recurring_valid_from(v_settle_id, v_first),
        NULL,     -- valid_to
        NULL,     -- status (default 'active')
        NULLIF(p->>'notes', ''));
    IF v_days IS NOT NULL THEN
        UPDATE finance.recurring_payments SET schedule_days_of_month = v_days WHERE id = v_rp_id;
    END IF;
    SELECT -monthly_equivalent INTO v_monthly FROM finance.recurring_payments WHERE id = v_rp_id;
    -- Depot-Kalender merken (gelernt aus der Nutzer-Antwort oder vorbelegt aus fn_broker_plan_days)
    PERFORM finance.fn_set_depot_plan_calendar(v_depot_id, v_sched);

    -- Karten-Hinweis (hohe Schwelle): aktiver Sparplan auf dasselbe Wertpapier (ISIN, sonst Symbol) im selben Depot
    SELECT sp.name INTO v_sim FROM finance.savings_plans sp
     WHERE sp.status = 'active' AND sp.depot_id = v_depot_id
       AND ((v_isin IS NOT NULL AND upper(sp.isin) = upper(v_isin))
            OR (v_isin IS NULL AND lower(sp.symbol) = lower(v_symbol)))
     ORDER BY sp.id LIMIT 1;

    -- 2. Sparplan-Eintrag
    INSERT INTO finance.savings_plans
        (name, depot_id, isin, symbol, security_name, recurring_payment_id, status, notes, beneficiary_person_id, asset_class)
    VALUES (
        p->>'name',
        v_depot_id,
        v_isin,
        v_symbol,
        v_sec_name,
        v_rp_id,
        'active',
        NULLIF(p->>'notes', ''),
        v_benef,                                  -- WS-4: genannte Person, sonst Depot-Inhaber (NULL = Haushalt/Joint)
        v_asset_cls                               -- WS-6: Anlageklasse (vererbt an jede Ausfuehrung; NULL = ungetaggt)
    )
    RETURNING id INTO v_plan_id;

    RETURN jsonb_build_object(
        'ok',                    true,
        'savings_plan_id',       v_plan_id,
        'recurring_payment_id',  v_rp_id,
        'card_lines',            finance.fn_similar_note(v_sim),
        'beneficiary_person_id', v_benef,
        'beneficiary_name',      (SELECT hp.full_name FROM core.fn_household_persons() hp WHERE hp.person_id = v_benef),
        'monthly_amount',        v_monthly,
        'schedule_unit',         v_unit,
        'schedule_interval',     v_interval,
        'schedule_day_of_month', v_dom,
        'schedule_days',         array_to_string(v_days, ', '),
        'effective',             (v_dates->'resolved') || jsonb_build_object('beneficiary_person_id', v_benef)
    )
    || CASE WHEN (v_sched->>'calendar_changed')::boolean AND jsonb_array_length(v_sched->'calendar') > 0
            THEN jsonb_build_object('calendar_learned',
                     (SELECT string_agg(e, ', ') FROM jsonb_array_elements_text(v_sched->'calendar') e))
            ELSE '{}'::jsonb END
    || finance.fn_savings_squeeze_fold();   -- neuer Sparplan kann das Girokonto leeren (gelatchter Sofort-Hinweis)
END;
$$;
