-- ============================================================
-- fn_create_savings_goal (ATOMIC WRITE)
--   Legt in EINER Transaktion an: (1) Sparziel, (2) recurring_payment
--   fuer die monatliche Sparrate + FK-Link. Invariante: recurring_payment_id
--   wird immer gesetzt (sonst fehlt der Posten im Cashflow).
--   RATE/ZIELDATUM RECHNET DIE DB (nicht das LLM, Root-CLAUDE.md *Das LLM rechnet NICHT*):
--   der Nutzer nennt target_amount + GENAU EINES von {target_date, monthly_savings_rate};
--   fn_savings_rate_schedule leitet die fehlende Groesse deterministisch ab (eine Quelle,
--   auch read-only fuer den HITL-Preview im Tool).
--   Eingabe jsonb: name, goal_type, target_amount, target_date (opt), monthly_savings_rate (opt),
--   account_id (Abbuchungskonto, in n8n aufgeloest), reserve_account_id (PFLICHT: Sparkonto/Topf, cash oder
--   fixed_deposit), schedule_day_of_month, first_payment_date (opt, WP2: leer = naechster Termin ab heute laut
--   fn_savings_rate_schedule), priority (opt, WS-C1: kleiner = wichtiger), notes,
--   beneficiary_person_id (opt, Slug; leer = Inhaber des Spartopfs, fn_default_beneficiary; Topf ohne Inhaber -> NULL).
--   SPARKONTO-PFLICHT (Audit Paket 3): ohne Topf liefe die Rate als nackte Abbuchung ins Leere -> Fortschritt 0,
--   Dauer-"hinter Plan", "erreicht" nie. Deshalb ist der Topf Gesetz in der fn (auch fuer den Import-Pfad), nicht
--   nur im Tool: fehlt / existiert nicht / nicht aktiv / nicht cash-fixed_deposit / gleich Abbuchungskonto -> {ok:false}.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, goal_id, recurring_payment_id, monthly_rate, target_date, first_payment_date, card_lines,
--   beneficiary_person_id, beneficiary_name (ueber core.fn_household_persons, D10), effective {beneficiary_person_id}}
--   + optional savings_squeeze (fn_savings_squeeze_fold) (monthly_rate/target_date = die berechnete bzw. uebernommene Groesse = Post-State; kein Echo der Eingabe
--   reserve_account_id).
--   Korrigierbar (Sparkonto fehlt/ungeeignet, Zielbetrag<=0, weder Datum noch Rate, Datum vor first_payment)
--   -> {ok:false, reason} OHNE Write (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_savings_goal(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_goal_id INT;
    v_rp_id   INT;
    v_sched   JSONB;
    v_sim     TEXT;
    v_rate    NUMERIC;
    v_date    DATE;
    v_acct    INT      := (p->>'account_id')::int;
    v_reserve INT      := NULLIF(p->>'reserve_account_id', '')::int;   -- WS-A: Ziel-Topf (Reserve-Konto)
    v_first   DATE;      -- erste Rate: genannt oder Default aus fn_savings_rate_schedule (WP2)
    v_dom     SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_why     TEXT;      -- fn_goal_reserve_account_reason
    v_benef   TEXT     := finance.fn_default_beneficiary(p->>'beneficiary_person_id', v_reserve);  -- genannt > Topf-Inhaber
    v_dates   JSONB;
BEGIN
    -- relative Datumsangaben ("in 2 years") -> ISO, damit effective sie fest in den Write nach der Karte traegt
    -- (fn_savings_rate_schedule loest dieselben Keys fuer die Karte auf); nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['target_date', 'first_payment_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Audit Paket 3: Sparkonto-Pflicht (Gesetz in der fn; Tool + Import pruefen vorab nur als Komfort).
    IF v_reserve IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A savings goal needs a savings account (reserve) where the money is kept - otherwise the '
                   || 'progress cannot be measured. Ask the user which savings/Tagesgeld account the rate goes to, '
                   || 'or offer to create one with tool_create_account first.');
    END IF;
    -- Konto-Regel des Topfs (eine Adresse mit set/relocate): aktives cash-/Festgeld-Konto, nicht das Abbuchungskonto.
    v_why := finance.fn_goal_reserve_account_reason(v_reserve, v_acct);
    IF v_why IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_why);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_acct AND status = 'active') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The funding (debit) account must be an active account.');
    END IF;
    -- Rate ODER Zieldatum deterministisch ableiten (kein LLM-Rechnen). Korrigierbare Faelle
    -- (Zielbetrag<=0, weder Datum noch Rate, Datum vor first_payment) kommen als {ok:false} zurueck.
    v_sched := finance.fn_savings_rate_schedule(p);
    IF (v_sched->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_sched;   -- {ok:false, reason} unveraendert durchreichen
    END IF;

    -- WS-A: die Rate ist eine UMBUCHUNG in den Reserve-Topf (statt reiner Abbuchung) ->
    -- der Fortschritt = Topf-Stand (s. savings_goal_progress); Topf <> Abbuchungskonto prueft die Konto-Regel oben.
    v_rate  := (v_sched->>'monthly_rate')::numeric;
    v_date  := (v_sched->>'target_date')::date;
    v_first := (v_sched->>'first_payment_date')::date;

    -- Karten-Hinweis (hohe Schwelle): aktives Sparziel mit gleichem Zielbetrag und gleichem Zieldatum
    SELECT g.name INTO v_sim FROM finance.savings_goals g
     WHERE g.status = 'active' AND g.target_amount = NULLIF(p->>'target_amount', '')::numeric AND g.target_date = v_date
     ORDER BY g.id LIMIT 1;

    -- 1. Sparziel (target_date = vom Helper aufgeloest, egal ob genannt oder berechnet)
    INSERT INTO finance.savings_goals
        (name, goal_type, target_amount, target_date, status, priority, notes, beneficiary_person_id)
    VALUES (
        p->>'name',
        NULLIF(p->>'goal_type', ''),
        (p->>'target_amount')::numeric,
        v_date,
        'active',
        NULLIF(p->>'priority', '')::smallint,     -- WS-C1: Engpass-Reihung (kleiner = wichtiger; leer=NULL=unpriorisiert)
        NULLIF(p->>'notes', ''),
        v_benef                                   -- WS-4: genannte Person, sonst Topf-Inhaber; NULL=Haushalt. FK->agent.persons.
    )
    RETURNING id INTO v_goal_id;

    -- 2. Sparrate als recurring_payment (monatlich, negativ = Ausgabe vom Konto)
    --    via gemeinsamen Helper (Teil 0: eine Quelle fuer den Insert).
    v_rp_id := finance.fn_add_recurring_payment(
        v_acct, -v_rate, left('Sparrate ' || (p->>'name'), 100),
        1::smallint, 'month'::finance.schedule_unit, v_dom, v_first, finance.fn_recurring_valid_from(v_acct, v_first), NULL, NULL, NULL);

    -- 3. FK-Link setzen
    UPDATE finance.savings_goals SET recurring_payment_id = v_rp_id WHERE id = v_goal_id;

    -- 4. WS-A: Rate wird Transfer in den Topf (target_account_id). fn_book_recurring_transfer bucht dann zwei-beinig
    --    und stempelt savings_goal_id aufs Haben-(Topf-)Bein -> Fortschritt = Topf-Stand.
    UPDATE finance.recurring_payments SET target_account_id = v_reserve WHERE id = v_rp_id;

    -- Phase L WS-4: Ueber-Spar-Sofort-Hinweis (Event-Fold, geteilter Helfer fn_savings_squeeze_fold). ERST HIER —
    -- nach dem target_account_id-UPDATE ist die Rate als Sparen in monthly_cashflow_summary. Auch bei schon
    -- bestehendem Pflicht-Defizit (frei < 0) warnt der Helfer - die neue Rate vertieft es; diese fn faltet kein
    -- cashflow_coverage, sonst bliebe die Anlage ohne jeden Hinweis.
    RETURN jsonb_build_object('ok', true, 'goal_id', v_goal_id, 'recurring_payment_id', v_rp_id,
        'monthly_rate', v_rate, 'target_date', v_date, 'first_payment_date', v_first,
        'card_lines', finance.fn_similar_note(v_sim),
        'beneficiary_person_id', v_benef,
        'beneficiary_name', (SELECT hp.full_name FROM core.fn_household_persons() hp WHERE hp.person_id = v_benef),
        'effective', (v_dates->'resolved') || jsonb_build_object('beneficiary_person_id', v_benef))
        || finance.fn_savings_squeeze_fold();
END;
$$;
