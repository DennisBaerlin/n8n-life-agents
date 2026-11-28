-- ============================================================
-- agent.fn_record_handoff_correction(p) (ATOMIC WRITE) — Korrektur eines erledigten Altbestand-Eintrags als NEUE Vormerkung
--   Ergebnis des Berater-Auftrags "Eintrag pruefen" (Knopf des Pruef-Schritts, core.fn_plan_rollout_next step check): ein
--   erledigter Eintrag ohne Soll stimmt nicht mit dem Plan ueberein -> eine neue Vormerkung mit follows_task_id, Abschnitt,
--   Thema und Paket der alten. Die alte bleibt unveraendert (Endzustaende aendert niemand); stimmt der alte Eintrag, gibt es
--   keinen Write. Die neue Vormerkung kommt wie jede andere ueber die Liste [Jetzt eintragen] zum Eintragen.
--   p: {chat_id (Pflicht, nie vom LLM), handoff_task_id (Pflicht, int oder Zahl-String), kind (savings_goal|savings_plan|
--     recurring_payment|recurring_transfer|other), payload (optional, Objekt oder JSON-String: Werkzeug-Eingabe wie beim
--     Vereinbaren), text (1..300, Alltags-Satz mit den Zahlen), why (optional, 1..160), option (optional: Schluessel der
--     gewaehlten Option der Vorpruefung)}.
--   Vorpruefung core.advisors.handoff_check_fn der Domain (mode agree) wie agent.fn_advisor_save_section: Aufruf -> wanted,
--   status open; unsupported + blocked_code (core.fn_handoff_blocked_codes) -> status deferred (mitgelieferter Aufruf wird
--   wanted); wirft die Paket-fn -> ohne wanted.
--   Rueckgabe {ok:true, task_id, status (open|deferred), blocked_code, card_lines: [core.hitl.handoff_note {text} bzw.
--     core.hitl.handoff_planned_deferred {text}, core.hitl.handoff_why {why} (nur mit why)]}.
--   Korrigierbar ohne Write {ok:false, code, reason}: handoff_task_invalid (unbekannt oder nicht die Person des Absenders),
--     handoff_task_not_closed (open/working/deferred: dafuer gibt es Eintragen bzw. den Korrektur-Schritt fix),
--     handoff_task_not_legacy (nicht done oder mit close_reason: im Register bzw. bewusst anders erledigt oder gestrichen),
--     handoff_not_permitted (Schreibrecht des Plan-Kontexts, agent.fn_check_write_permission),
--     handoff_task_followed (hat schon eine Folge-Aufgabe; UNIQUE follows_task_id ist der Backstop), handoff_kind_invalid,
--     handoff_text_invalid, handoff_why_too_long, invalid payload, unknown_blocked_code, Ablehnungen der Vorpruefung
--     (Kandidaten/Optionen als Satz im reason, core.fn_handoff_check_hint).
--   INVOKER unter der Host-Cred (Core-Werkzeug agent.tool_record_handoff_correction).
--   Tests: tests/db/core/test_fn_record_handoff_correction.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_record_handoff_correction(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid     text := core.fn_handoff_person(p->>'chat_id');
    v_old     agent.handoff_tasks%ROWTYPE;
    v_text    text := btrim(COALESCE(p->>'text', ''));
    v_why     text := NULLIF(btrim(COALESCE(p->>'why', '')), '');
    v_kind    text := btrim(COALESCE(p->>'kind', ''));
    v_payload jsonb;
    v_chkfn   regprocedure;
    v_chk     jsonb;
    v_wanted  jsonb;
    v_code    text;
    v_id      int;
    v_err     text;
BEGIN
    IF v_pid IS NULL OR COALESCE(p->>'handoff_task_id', '') !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid', 'reason', 'Unknown entry for this person.');
    END IF;
    SELECT * INTO v_old FROM agent.handoff_tasks h WHERE h.id = (p->>'handoff_task_id')::int AND h.person_id = v_pid FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid', 'reason', 'Unknown entry for this person.');
    END IF;
    IF v_old.status NOT IN ('done', 'cancelled') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_not_closed',
            'reason', format('Entry %s is still %s; only a closed entry gets a correction.', v_old.id, v_old.status));
    END IF;
    -- Nur Altbestand: mit close_reason Abgeschlossenes steht entweder im Register (entered mit Soll, core.fn_handoff_register)
    -- oder ist bewusst anders erledigt bzw. gestrichen (Entscheidung des Nutzers).
    IF v_old.status <> 'done' OR v_old.close_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_not_legacy',
            'reason', format('Entry %s was not entered before the agreed call was kept; only such an entry gets a correction here.', v_old.id));
    END IF;
    -- Schreibrecht wie die Plan-Writes (Registry core.context_scopes des Plan-Kontexts; Haushaltsplan owner_only)
    v_err := agent.fn_check_write_permission(
        COALESCE((SELECT cs.write_permission FROM core.context_scopes cs JOIN core.advisors a ON a.plan_context = cs.context_name
                   WHERE a.domain = v_old.domain), 'owner_only'),
        p->>'chat_id', v_pid);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_permitted', 'reason', 'Only the person who keeps this plan can correct its entries.');
    END IF;
    IF EXISTS (SELECT 1 FROM agent.handoff_tasks f WHERE f.follows_task_id = v_old.id) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_followed',
            'reason', format('Entry %s already has a correction.', v_old.id));
    END IF;
    -- Spiegel des CHECK an agent.handoff_tasks.kind (Backstop bleibt der CHECK)
    IF v_kind NOT IN ('savings_goal', 'savings_plan', 'recurring_payment', 'recurring_transfer', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_kind_invalid',
            'reason', 'kind must be savings_goal, savings_plan, recurring_payment, recurring_transfer or other.');
    END IF;
    IF length(v_text) NOT BETWEEN 1 AND 300 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_text_invalid', 'reason', 'text must be one plain sentence of 1 to 300 characters.');
    END IF;
    IF length(v_why) > 160 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_why_too_long', 'max', 160, 'reason', 'why must be one sentence of at most 160 characters.');
    END IF;
    IF jsonb_typeof(p->'payload') = 'string' AND btrim(p->>'payload') <> '' THEN
        BEGIN
            v_payload := (p->>'payload')::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'payload is not valid JSON: ' || left(p->>'payload', 120));
        END;
    ELSE
        v_payload := NULLIF(p->'payload', 'null'::jsonb);
    END IF;
    v_payload := COALESCE(NULLIF(v_payload, '""'::jsonb), '{}'::jsonb);
    IF jsonb_typeof(v_payload) <> 'object' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'payload must be a JSON object.');
    END IF;

    -- Registry-Name ist per CHECK auf <schema>.fn_<name> begrenzt, nie Nutzereingabe.
    v_chkfn := to_regprocedure((SELECT a.handoff_check_fn FROM core.advisors a WHERE a.domain = v_old.domain) || '(jsonb)');
    IF v_chkfn IS NOT NULL THEN
        BEGIN
            EXECUTE format('SELECT %s($1)', v_chkfn::regproc) INTO v_chk USING jsonb_build_object(
                'mode', 'agree', 'domain', v_old.domain, 'chat_id', p->>'chat_id', 'kind', v_kind,
                'payload', v_payload, 'text', v_text, 'option', NULLIF(btrim(COALESCE(p->>'option', '')), ''));
        EXCEPTION WHEN OTHERS THEN
            v_chk := NULL;
        END;
    END IF;
    IF v_chk IS NOT NULL AND v_chk->'ok' IS DISTINCT FROM 'true'::jsonb THEN
        RETURN v_chk || jsonb_build_object('ok', false, 'code', COALESCE(v_chk->>'code', 'handoff_not_enterable'),
            'reason', COALESCE(v_chk->>'reason', 'The entry cannot be entered like this.') || core.fn_handoff_check_hint(v_chk, p->>'chat_id'));
    END IF;
    IF v_chk->'unsupported' = 'true'::jsonb THEN
        v_code := COALESCE(v_chk->>'blocked_code', '');
        IF NOT (core.fn_handoff_blocked_codes(v_old.package) ? v_code) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'unknown_blocked_code', 'valid_codes', core.fn_handoff_blocked_codes(v_old.package),
                'reason', 'The entry check returned an unknown blocked_code.');
        END IF;
    END IF;
    v_wanted := CASE WHEN jsonb_typeof(v_chk->'calls') = 'array' THEN v_chk->'calls'
                     WHEN jsonb_typeof(v_chk->'call') = 'object' THEN v_chk->'call' END;

    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text, why, wanted,
                                     status, blocked_code, follows_task_id)
    VALUES (v_old.domain, v_old.package, v_pid, v_old.section_key, v_old.topic, v_kind, v_payload, v_text, v_why, v_wanted,
            CASE WHEN v_code IS NOT NULL THEN 'deferred' ELSE 'open' END, v_code, v_old.id)
    ON CONFLICT (follows_task_id) WHERE follows_task_id IS NOT NULL DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_followed', 'reason', format('Entry %s already has a correction.', v_old.id));
    END IF;

    RETURN jsonb_build_object('ok', true, 'task_id', v_id,
        'status', CASE WHEN v_code IS NOT NULL THEN 'deferred' ELSE 'open' END,
        'blocked_code', v_code,
        'card_lines', jsonb_build_array(jsonb_build_object('kind', 'note',
                          'value', CASE WHEN v_code IS NOT NULL THEN 'core.hitl.handoff_planned_deferred' ELSE 'core.hitl.handoff_note' END,
                          'params', jsonb_build_object('text', v_text)))
                      || CASE WHEN v_why IS NOT NULL THEN jsonb_build_array(jsonb_build_object('kind', 'note',
                              'value', 'core.hitl.handoff_why', 'params', jsonb_build_object('why', v_why))) ELSE '[]'::jsonb END);
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_record_handoff_correction(jsonb) FROM public;
