-- ============================================================
-- fn_bank_note_recorded (WRITE) -- Karten-Notiz zum Bank-Hinweis und offener Bank-Punkt der Kette in einem Aufruf
--   Eingabe wie fn_bank_setup_note (p_rp_id beliebiges Glied, p_event 'bank_setup'|'bank_change'|'bank_stop', p_params).
--   Rueckgabe: die Notiz. Leere Notiz -> kein Punkt. Offener Punkt je Kopf hoechstens einer (Partial-UNIQUE):
--     setup+change bleibt setup; setup+stop bleibt setup, lief die eigene Kette schon -> stop; change+stop -> stop;
--     stop+setup/change -> change, lief die eigene Kette nie -> setup; change ohne offenen Punkt und nie gelaufen -> setup.
--   Aendert sich die Art eines schon gesendeten Punkts, entsteht eine neue Zeile: Die Merker haengen an der id.
--   Probelauf rollt alles zurueck. Tests: tests/db/finance/test_fn_bank_todos.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_note_recorded(p_rp_id int, p_event text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_note jsonb := finance.fn_bank_setup_note(p_rp_id, p_event, p_params);
    v_new  text := CASE p_event WHEN 'bank_setup' THEN 'setup' WHEN 'bank_change' THEN 'change' WHEN 'bank_stop' THEN 'stop' END;
    v_head int;
    v_ran  boolean;
    v_row  finance.bank_todos%ROWTYPE;
    v_res  text;
BEGIN
    IF v_new IS NULL THEN RAISE EXCEPTION 'fn_bank_note_recorded: unknown event %', p_event; END IF;
    IF v_note = '[]'::jsonb THEN RETURN v_note; END IF;
    v_head := finance.fn_recurring_lineage_head(p_rp_id);
    v_ran := EXISTS (SELECT 1 FROM finance.transactions t WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head)));
    SELECT * INTO v_row FROM finance.bank_todos WHERE head_id = v_head AND status = 'open' FOR UPDATE;
    IF NOT FOUND THEN
        v_res := CASE WHEN v_new = 'change' AND NOT v_ran THEN 'setup' ELSE v_new END;
        INSERT INTO finance.bank_todos (head_id, event) VALUES (v_head, v_res);
        RETURN v_note;
    END IF;
    v_res := CASE
        WHEN v_row.event = 'setup' AND v_new = 'stop' AND v_ran THEN 'stop'
        WHEN v_row.event = 'setup' THEN 'setup'
        WHEN v_row.event = 'change' AND v_new = 'stop' THEN 'stop'
        WHEN v_row.event = 'change' THEN 'change'
        WHEN v_new = 'stop' THEN 'stop'
        WHEN NOT v_ran THEN 'setup'
        ELSE 'change' END;
    IF v_res <> v_row.event AND v_row.first_sent_at IS NOT NULL THEN
        UPDATE finance.bank_todos SET status = 'done', closed_at = now() WHERE id = v_row.id;
        INSERT INTO finance.bank_todos (head_id, event, source) VALUES (v_head, v_res, v_row.source);
    ELSE
        UPDATE finance.bank_todos SET event = v_res, event_at = now() WHERE id = v_row.id;
    END IF;
    RETURN v_note;
END $$;

-- ============================================================
-- fn_bank_todo_visible (READ) -- darf dieser offene Bank-Punkt angezeigt und gemahnt werden?
--   Alles wird beim Lesen aus der Kette abgeleitet: eine gebuchte Zahlung laesst setup verschwinden, ein Void holt ihn
--   zurueck. Alle: status open und fn_bank_setup_kind nicht NULL. setup: Kette aktiv, eigene Kette ohne Buchung, noch ein
--   Termin offen. change: Kette aktiv. stop: nicht von fn_bank_end_due abgedeckt (Kette mit Ende und aktiv meldet dort)
--   und event_at hoechstens 60 Tage alt. Eingabe: p_id. Rueckgabe boolean. plpgsql: spaetere R__.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_todo_visible(p_id int)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    t finance.bank_todos%ROWTYPE;
    h finance.recurring_payments%ROWTYPE;
    v_last date;
BEGIN
    SELECT * INTO t FROM finance.bank_todos WHERE id = p_id AND status = 'open';
    IF NOT FOUND THEN RETURN false; END IF;
    IF finance.fn_bank_setup_kind(t.head_id, t.event <> 'setup') IS NULL THEN RETURN false; END IF;
    SELECT * INTO h FROM finance.recurring_payments WHERE id = t.head_id;
    IF t.event = 'setup' THEN
        v_last := finance.fn_recurring_last_due(t.head_id);
        RETURN h.status = 'active'
           AND NOT EXISTS (SELECT 1 FROM finance.transactions x WHERE x.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(t.head_id)))
           AND (v_last IS NULL OR v_last >= core.fn_today());
    ELSIF t.event = 'change' THEN
        RETURN h.status = 'active';
    END IF;
    RETURN NOT (h.status = 'active' AND h.valid_to IS NOT NULL) AND t.event_at >= now() - interval '60 days';
END $$;

-- ============================================================
-- fn_bank_todo_item (READ) -- Anzeige-Zeile eines Bank-Punkts aus der Kette (Betrag, Rhythmus, Start, Ende nie gespeichert)
--   Rueckgabe: {id, head, event, source, kind, bank|null, holder_person_id|null, holder_name|null, holder_role|null, name,
--   line:[tpl...]}. Inhaber = owner_person_id des Quell-Kontos, beim Sparplan des Depots (wie fn_bank_end_due).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_todo_item(p_id int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', t.id, 'head', t.head_id, 'event', t.event, 'source', t.source, 'kind', k.kind,
        'bank', NULLIF(btrim(CASE WHEN k.kind = 'savings_plan' THEN dep.bank ELSE src.bank END), ''),
        'holder_person_id', p.person_id, 'holder_name', split_part(p.full_name, ' ', 1), 'holder_role', p.role,
        'name', COALESCE(sp.name, h.name),
        'line', jsonb_build_array(
            core.fn_ui_tpl(CASE t.event || ':' || k.kind
                WHEN 'setup:standing_order'  THEN 'finance.bank_todo.line_setup_standing_order'
                WHEN 'setup:savings_plan'    THEN 'finance.bank_todo.line_setup_savings_plan'
                WHEN 'change:standing_order' THEN 'finance.bank_todo.line_change_standing_order'
                WHEN 'change:savings_plan'   THEN 'finance.bank_todo.line_change_savings_plan'
                WHEN 'stop:standing_order'   THEN 'finance.bank_todo.line_stop_standing_order'
                ELSE 'finance.bank_todo.line_stop_savings_plan' END,
                jsonb_build_object('name', COALESCE(sp.name, h.name), 'amount', core.fn_ui_money(abs(h.amount), src.currency))),
            CASE WHEN cardinality(h.schedule_days_of_month) > 0 THEN core.fn_ui_tpl('finance.bank_todo.rhythm_days',
                     jsonb_build_object('days', array_to_string(h.schedule_days_of_month, ', ')))
                 WHEN h.schedule_unit = 'month' AND COALESCE(h.schedule_interval, 1) = 1 AND h.schedule_day_of_month > 0 THEN
                     core.fn_ui_tpl('finance.bank_todo.rhythm_month', jsonb_build_object('day', h.schedule_day_of_month::text))
                 WHEN h.schedule_unit = 'month' AND COALESCE(h.schedule_interval, 1) = 1 AND h.schedule_day_of_month = -1 THEN
                     core.fn_ui_tpl('finance.bank_todo.rhythm_month_last')
                 WHEN h.schedule_unit = 'month' AND COALESCE(h.schedule_interval, 1) = 1 AND h.schedule_day_of_month = -2 THEN
                     core.fn_ui_tpl('finance.bank_todo.rhythm_month_second_last')
                 WHEN h.schedule_unit = 'month' AND COALESCE(h.schedule_interval, 1) = 1 THEN core.fn_ui_tpl('finance.bank_todo.rhythm_monthly')
                 ELSE core.fn_ui_tpl('finance.bank_todo.rhythm_other', jsonb_build_object(
                     'n', COALESCE(h.schedule_interval, 1)::text,
                     'unit', jsonb_build_object('kind', 'enum', 'enum', 'finance.enum.schedule_unit', 'value', h.schedule_unit))) END,
            CASE WHEN t.event = 'setup' AND GREATEST(h.first_payment_date, h.valid_from) >= core.fn_today()
                 THEN core.fn_ui_tpl('finance.bank_todo.start', jsonb_build_object('date', core.fn_ui_date(GREATEST(h.first_payment_date, h.valid_from)))) END,
            CASE WHEN t.event <> 'stop' AND finance.fn_recurring_last_due(t.head_id) IS NOT NULL
                 THEN core.fn_ui_tpl('finance.bank_todo.last', jsonb_build_object('date', core.fn_ui_date(finance.fn_recurring_last_due(t.head_id)))) END,
            CASE WHEN k.kind = 'standing_order' THEN core.fn_ui_tpl('finance.bank_todo.route', jsonb_build_object(
                     'from', src.name, 'to', tgt.name,
                     'iban', COALESCE(' (' || NULLIF(btrim(tgt.account_number), '') || ')', ''))) END,
            CASE WHEN t.source = 'backfill' THEN core.fn_ui_tpl('finance.bank_todo.if_not_yet') END))
      INTO v
      FROM finance.bank_todos t
      JOIN finance.recurring_payments h ON h.id = t.head_id
      JOIN finance.accounts src ON src.id = h.account_id
      LEFT JOIN finance.accounts tgt ON tgt.id = h.target_account_id
      CROSS JOIN LATERAL (SELECT finance.fn_bank_setup_kind(t.head_id, t.event <> 'setup') AS kind) k
      LEFT JOIN LATERAL (SELECT s.name, s.depot_id FROM finance.savings_plans s
                          WHERE s.recurring_payment_id = t.head_id ORDER BY s.id LIMIT 1) sp ON true
      LEFT JOIN finance.accounts dep ON dep.id = sp.depot_id
      LEFT JOIN core.fn_household_persons() p
             ON p.person_id = CASE WHEN k.kind = 'savings_plan' THEN dep.owner_person_id ELSE src.owner_person_id END
     WHERE t.id = p_id;
    RETURN v;
END $$;

-- ============================================================
-- fn_bank_todo_group (READ) -- Gruppen je (Bank, Inhaber, Nachfassen) aus Item-Zeilen
--   Eingabe: jsonb-Array aus fn_bank_todo_item, optional mit round. Rueckgabe: [{bank, holder_person_id, holder_name,
--   nudge, first_id, max_id, items}]. first_id/max_id tragen den Knopf btodo:<first>:<max>.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_todo_group(p_items jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(g ORDER BY g->>'bank' NULLS LAST, g->>'holder_person_id' NULLS FIRST, (g->>'nudge')::boolean), '[]'::jsonb)
      FROM (
        SELECT jsonb_build_object(
                 'bank', i->>'bank', 'holder_person_id', i->>'holder_person_id', 'holder_name', max(i->>'holder_name'),
                 'nudge', COALESCE((i->>'round')::int, 0) > 0,
                 'first_id', min((i->>'id')::int), 'max_id', max((i->>'id')::int),
                 'items', jsonb_agg(i ORDER BY (i->>'id')::int)) AS g
          FROM jsonb_array_elements(p_items) i
         GROUP BY i->>'bank', i->>'holder_person_id', COALESCE((i->>'round')::int, 0) > 0) x;
$$;

-- ============================================================
-- fn_bank_todo_groups (READ) -- sichtbare Punkte, die dieser Absender sehen darf, je Bank
--   Owner alles, erwachsenes Mitglied (partner) nur die eigenen, Kind oder unbekannt nichts. Eingabe: p_chat_id (Text).
--   Rueckgabe wie fn_bank_todo_group. Schreibt nichts. Tests: tests/db/finance/test_fn_bank_todos.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_todo_groups(p_chat_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_s jsonb;
BEGIN
    IF COALESCE(p_chat_id, '') !~ '^[0-9]{1,18}$' THEN RETURN '[]'::jsonb; END IF;
    v_s := agent.fn_resolve_sender(p_chat_id::bigint);
    IF v_s->>'role' IS NULL OR v_s->>'role' NOT IN ('owner', 'partner') THEN RETURN '[]'::jsonb; END IF;
    RETURN finance.fn_bank_todo_group(COALESCE((
        SELECT jsonb_agg(i)
          FROM finance.bank_todos t
          CROSS JOIN LATERAL finance.fn_bank_todo_item(t.id) i
         WHERE t.status = 'open' AND finance.fn_bank_todo_visible(t.id)
           AND (v_s->>'role' = 'owner' OR i->>'holder_person_id' = v_s->>'person_id')), '[]'::jsonb));
END $$;

-- ============================================================
-- fn_bank_todo_backfill (WRITE) -- holt Bank-Punkte aus Uebergabe-Aufgaben von vor dem Update einmalig nach
--   Einmal-Merker in core.notification_state. Treffer: created_at des Wurzel-Glieds = closed_at einer done-Aufgabe, eigene
--   Kette lief nie, Kette hat noch keinen Punkt in irgendeinem Status. fn_recurring_never_ran bewusst nicht: Sie schaut
--   auch auf andere Ketten derselben Strecke. Rueckgabe: void.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_todo_backfill()
RETURNS void LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    IF NOT core.fn_should_notify('finance:bank_todo', '__backfill__') THEN RETURN; END IF;
    INSERT INTO finance.bank_todos (head_id, event, source)
    SELECT h.head, 'setup', 'backfill'
      FROM (SELECT DISTINCT finance.fn_recurring_lineage_head(id) AS head FROM finance.recurring_payments) h
     WHERE NOT EXISTS (SELECT 1 FROM finance.bank_todos t WHERE t.head_id = h.head)
       AND finance.fn_bank_setup_kind(h.head) IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM finance.transactions x WHERE x.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(h.head)))
       AND (SELECT min(r.created_at) FROM finance.recurring_payments r WHERE r.id IN (SELECT finance.fn_recurring_lineage(h.head)))
           IN (SELECT core.fn_handoff_done_stamps('finance'));
END $$;

-- ============================================================
-- fn_bank_todo_claim (WRITE, Latch) -- die heute faelligen Bank-Nachrichten je Empfaenger, jede genau einmal
--   p_mode 'cron': Runde 0 ab 20 Stunden, Nachfass-Runden nach first_sent_at (finance.bank_todo_nudge_days, Default Tag 7 und 21) (beide faellig ->
--   nur die spaetere, stop nie nachgefasst, frueher als 7 Tage vor dem ersten Termin nie). p_mode 'handoff': nur Runde 0
--   und nur Punkte aus der Uebergabe (created_at = closed_at einer done-Aufgabe) oder nachgeholte.
--   Empfaenger wie fn_bank_end_claim: Owner alle (cron_enable.remind_bank_todo), Inhaber partner mit Kopplung die eigenen
--   (remind_bank_todo_person), Kinder nie. Merker 'finance:bank_todo', Key <id>:r<runde>:owner|<person_id>, je Empfaenger:
--   Wer heute nicht darf, verliert nichts; im Modus cron Budget je Empfaenger (Slot 'bank_todo' normal, ohne Platz kein Merker). handoff beansprucht 30 Minuten und liefert latches (Commit/Reset macht core.sub_plan_rollout_next via finance.fn_plan_rollout ueber core.fn_notify_commit/core.fn_notify_resolve).
--   Eingaben: p_on (default heute), p_mode. Rueckgabe: [{recipient, chat_id, groups, latches}], Owner zuerst. Setzt
--   first_sent_at. Tests: tests/db/finance/test_fn_bank_todos.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_todo_claim(p_on date DEFAULT core.fn_today(), p_mode text DEFAULT 'cron')
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    c_src     CONSTANT text := 'finance:bank_todo';
    v_ok      boolean := core.fn_reminder_allowed('remind_bank_todo', NULL);
    v_ttl     interval := CASE WHEN p_mode = 'handoff' THEN interval '30 minutes' END;
    v_owner   jsonb := '[]'::jsonb;
    v_olatch  jsonb := '[]'::jsonb;
    v_people  jsonb := '{}'::jsonb;
    t         finance.bank_todos%ROWTYPE;
    h         finance.recurring_payments%ROWTYPE;
    v_item    jsonb;
    v_round   int;
    v_days    int;
    v_nudge   text[] := string_to_array(COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'bank_todo_nudge_days'), ''), '7,21'), ',');
    v_pid     text;
    v_chat    bigint;
    v_key     text;
    v_sent    boolean;
    v_person  jsonb;
    v_out     jsonb;
    v_oroom   boolean;              -- Budget nur im Cron: handoff ist Folge einer Handlung
    v_proom   jsonb := '{}'::jsonb;
BEGIN
    PERFORM finance.fn_bank_todo_backfill();
    PERFORM core.fn_notify_forget_before(c_src, (p_on - 400)::timestamptz);
    FOR t IN SELECT * FROM finance.bank_todos WHERE status = 'open' ORDER BY id LOOP
        CONTINUE WHEN NOT finance.fn_bank_todo_visible(t.id);
        v_days := p_on - t.first_sent_at::date;
        IF p_mode = 'handoff' THEN
            CONTINUE WHEN NOT (t.source = 'backfill' OR t.created_at IN (SELECT core.fn_handoff_done_stamps('finance')));
            CONTINUE WHEN v_days IS NOT NULL AND v_days >= v_nudge[1]::int;
            v_round := 0;
        ELSIF t.first_sent_at IS NULL THEN
            CONTINUE WHEN now() - t.created_at < interval '20 hours';
            v_round := 0;
        ELSE
            v_round := CASE WHEN v_days < v_nudge[1]::int THEN 0 WHEN v_days < v_nudge[2]::int THEN 1 ELSE 2 END;
            CONTINUE WHEN v_round > 0 AND t.event = 'stop';
            IF v_round > 0 THEN
                SELECT * INTO h FROM finance.recurring_payments WHERE id = t.head_id;
                CONTINUE WHEN p_on < GREATEST(h.first_payment_date, h.valid_from) - 7;
            END IF;
        END IF;

        v_item := finance.fn_bank_todo_item(t.id) || jsonb_build_object('round', v_round);
        v_pid  := v_item->>'holder_person_id';
        v_sent := false;
        v_key  := t.id || ':r' || v_round || ':owner';
        IF v_ok AND p_mode = 'cron' AND v_oroom IS NULL AND NOT core.fn_notify_told(c_src, v_key) THEN
            v_oroom := core.fn_proactive_claim(NULL, 'bank_todo', 'normal');
        END IF;
        IF v_ok AND (p_mode <> 'cron' OR v_oroom) AND core.fn_should_notify(c_src, v_key, v_ttl) THEN
            v_owner := v_owner || CASE WHEN v_item->>'holder_role' = 'owner'
                                       THEN jsonb_set(v_item, '{holder_name}', 'null') ELSE v_item END;
            v_olatch := v_olatch || jsonb_build_object('source', c_src, 'key', v_key);
            v_sent := true;
        END IF;
        IF v_item->>'holder_role' = 'partner' THEN
            v_chat := core.fn_person_chat_id(v_pid);
            v_key  := t.id || ':r' || v_round || ':' || v_pid;
            IF p_mode = 'cron' AND v_chat IS NOT NULL AND core.fn_reminder_allowed('remind_bank_todo_person', v_pid)
               AND NOT v_proom ? v_pid AND NOT core.fn_notify_told(c_src, v_key) THEN
                v_proom := v_proom || jsonb_build_object(v_pid, core.fn_proactive_claim(v_pid, 'bank_todo', 'normal'));
            END IF;
            IF v_chat IS NOT NULL AND core.fn_reminder_allowed('remind_bank_todo_person', v_pid)
               AND (p_mode <> 'cron' OR COALESCE((v_proom->>v_pid)::boolean, false))
               AND core.fn_should_notify(c_src, v_key, v_ttl) THEN
                v_person := COALESCE(v_people->v_pid, jsonb_build_object('recipient', v_pid, 'chat_id', v_chat, 'items', '[]'::jsonb, 'latches', '[]'::jsonb));
                v_people := jsonb_set(v_people, ARRAY[v_pid], v_person
                    || jsonb_build_object('items', (v_person->'items') || v_item,
                                          'latches', (v_person->'latches') || jsonb_build_object('source', c_src, 'key', v_key)), true);
                v_sent := true;
            END IF;
        END IF;
        IF v_sent AND t.first_sent_at IS NULL THEN
            UPDATE finance.bank_todos SET first_sent_at = now() WHERE id = t.id;
        END IF;
    END LOOP;

    SELECT CASE WHEN jsonb_array_length(v_owner) > 0
                THEN jsonb_build_array(jsonb_build_object('recipient', 'owner', 'chat_id', NULL,
                         'groups', finance.fn_bank_todo_group(v_owner), 'latches', v_olatch))
                ELSE '[]'::jsonb END
           || COALESCE((SELECT jsonb_agg(jsonb_build_object('recipient', value->'recipient', 'chat_id', value->'chat_id',
                                         'groups', finance.fn_bank_todo_group(value->'items'), 'latches', value->'latches') ORDER BY key)
                          FROM jsonb_each(v_people)), '[]'::jsonb)
      INTO v_out;
    RETURN v_out;
END $$;
