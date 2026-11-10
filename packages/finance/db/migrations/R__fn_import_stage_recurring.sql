-- ============================================================
-- fn_import_stage_recurring (Staging-Write, KEIN HITL: Staging ist keine Domaenen-Daten) -- Dauerauftrags-Vorschlaege
--   eines Kontoauszugs oder Bank-Exports in den EINEN offenen Vorschlags-Stapel des Chats legen
--   Bucht nichts und legt keinen Dauerauftrag an; angelegt wird nur per Knopf (fn_handle_recurring_suggestion_cb).
--   mode statement (tool_reconcile_bank_statement): Konto und Saldo-Probe kommen aus fn_statement_prepare (eine Adresse);
--   balance_verified false -> nichts erkannt, hint balance_check_failed (Lesefehler kommen nie auf eine Nachricht).
--   Erkennung fn_get_recurring_candidates mode statement. mode export (tool_import_recurring_suggestions):
--   fn_get_recurring_suggestions (with_dates); dessen Codes und hint export_too_short gehen unveraendert zurueck.
--   Stapel: alle Zeilen mit origin recurring_suggestion und dieser chat_id (vorher fn_import_sweep). Je Vorschlag:
--   Haushaltsmitglied ohne eigenes Konto -> household[] (der Agent fragt einzeln); gleichnamige laufende Zahlung
--   (fn_recurring_name_check) -> hints name_taken. Zuordnung zu einer Stapelzeile desselben Kontos und derselben Art:
--   Gegen-IBAN, dann Mandat, dann gleicher series- bzw. Name (zwei verschiedene IBANs nie). Getroffen: Termine anhaengen
--   (gleicher Zeitraum desselben Kontos ersetzt dessen Termine, gleiche Termine Datum+Betrag zaehlen einmal);
--   committed -> nichts; declined -> nur Termine (bleibt abgelehnt); offen und neue Termine -> neu gemessen
--   (fn_recurring_suggestion_measure), version + 1 (eine schon geschickte Nachricht meldet beim Tipp "ueberholt").
--   Nicht getroffen: neue offene Zeile (Name im Stapel eindeutig gemacht). merged_at = jetzt bei jedem Ergaenzen.
--   Payload einer Zeile = Werte des Anlege-Werkzeugs (fn_create_recurring_payment bzw. _transfer) plus account_id
--   (Konto des Auszugs), counterparty_iban, creditor_id, mandate_ref, recurring_kind, series, rhythm_hint,
--   origin_kind, occurrences:[{date, amount (mit Vorzeichen), account_id, period_start, period_end}]; die Sicherheit
--   wird nicht gespeichert (beim Anzeigen aus den Terminen). Im Stapel liegen keine Verwendungszwecke, keine uebrigen Zeilen.
--   Eingabe p: {chat_id*, mode (statement|export), statement: account_id*, balance_verified*, period_start, period_end,
--   lines*[] (mit recurring_kind, series, rhythm_hint); export: account_name, table}.
--   RUECKGABE: {ok:true, account_name, staged, updated, open_count, unsent_count, rows:[{nr, name}], sure_count,
--   confirm_count, hints:[{kind:'area'|'name_taken', area?, name}], household:[{name, amount}], known_elsewhere,
--   months_seen, months_missing (YYYY-MM, nur statement: die drei Monate bis zum juengsten Auszug), hint?}
--   | {ok:false, reason} (ohne chat_id/Konto) | Codes von fn_bank_export_load.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_stage_recurring(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_chat    TEXT := NULLIF(btrim(COALESCE(p->>'chat_id', '')), '');
    v_mode    TEXT := COALESCE(NULLIF(p->>'mode', ''), 'statement');
    v_acct    finance.accounts%ROWTYPE;
    v_r       JSONB;
    v_cand    JSONB;
    v_ps      DATE;
    v_pe      DATE;
    v_src     TEXT;
    v_hint    TEXT;
    v_batch   UUID;
    v_s       JSONB;
    v_row     RECORD;
    v_entity  TEXT;
    v_name    TEXT;
    v_series  TEXT;
    v_iban    TEXT;
    v_other   INT;
    v_pl      JSONB;
    v_new     JSONB;
    v_occ     JSONB;
    v_m       JSONB;
    v_nc      JSONB;
    v_n       INT;
    v_staged  INT := 0;
    v_updated INT := 0;
    v_hints   JSONB := '[]'::jsonb;
    v_house   JSONB := '[]'::jsonb;
    v_elsewh  JSONB := '[]'::jsonb;
    v_seen    TEXT[];
    v_target  TEXT[];
    v_sure    INT := 0;
    v_conf    INT := 0;
BEGIN
    IF v_chat IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'chat_id is required');
    END IF;
    IF v_mode = 'export' THEN
        v_r := finance.fn_get_recurring_suggestions(p || jsonb_build_object('with_dates', true));
        IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'hint' = 'export_too_short' THEN
            RETURN v_r;
        END IF;
        SELECT * INTO v_acct FROM finance.accounts WHERE id = (v_r->>'account_id')::int;
        v_ps := (v_r->>'period_first')::date; v_pe := (v_r->>'period_last')::date; v_src := 'csv';
        v_hint := v_r->>'hint';
        v_cand := jsonb_build_object('suggestions', v_r->'suggestions', 'known_elsewhere', v_r->'known_elsewhere', 'hints', '[]'::jsonb);
    ELSIF v_mode = 'statement' THEN
        SELECT * INTO v_acct FROM finance.accounts WHERE id = NULLIF(p->>'account_id', '')::int;
        IF v_acct.id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'account_id of the statement is required');
        END IF;
        v_ps := NULLIF(p->>'period_start', '')::date; v_pe := NULLIF(p->>'period_end', '')::date; v_src := 'vision';
        IF COALESCE((p->>'balance_verified')::boolean, false) THEN
            -- Kategorie ausserhalb der Liste des Lese-Schemas (enum) = kein Modell-Ergebnis, sondern Fremdtext -> Zeile raus;
            -- leer bleibt (fn_recurring_kind_policy: other)
            v_cand := finance.fn_get_recurring_candidates(jsonb_build_object('account_id', v_acct.id, 'mode', 'statement',
                          'period_last', v_pe, 'lines', COALESCE((SELECT jsonb_agg(l) FROM jsonb_array_elements(COALESCE(p->'lines', '[]'::jsonb)) l
                              WHERE NULLIF(btrim(COALESCE(l->>'recurring_kind', '')), '') IS NULL
                                 OR finance.fn_recurring_kind_policy(l->>'recurring_kind')->>'kind' = lower(btrim(l->>'recurring_kind'))
                                 OR lower(btrim(l->>'recurring_kind')) = 'other'), '[]'::jsonb)));
        ELSE
            v_hint := 'balance_check_failed';
            v_cand := jsonb_build_object('suggestions', '[]'::jsonb, 'known_elsewhere', '[]'::jsonb, 'hints', '[]'::jsonb);
        END IF;
    ELSE
        RETURN jsonb_build_object('ok', false, 'reason', 'mode must be statement or export');
    END IF;

    PERFORM finance.fn_import_sweep(7);
    SELECT s.batch_id INTO v_batch FROM finance.import_staging s
    WHERE s.origin = 'recurring_suggestion' AND s.chat_id = v_chat
    ORDER BY s.merged_at DESC NULLS LAST, s.id DESC LIMIT 1;
    v_batch := COALESCE(v_batch, gen_random_uuid());
    v_hints := COALESCE(v_cand->'hints', '[]'::jsonb);
    SELECT COALESCE(jsonb_agg(jsonb_build_object('name', finance.fn_recurring_clean_name(e->>'name'), 'account_name', e->>'account_name')), '[]'::jsonb)
    INTO v_elsewh FROM jsonb_array_elements(COALESCE(v_cand->'known_elsewhere', '[]'::jsonb)) e;

    FOR v_s IN SELECT s FROM jsonb_array_elements(v_cand->'suggestions') s LOOP
        v_name := COALESCE(finance.fn_recurring_clean_name(v_s->>'name'), finance.fn_recurring_clean_name(v_s->>'series'));
        CONTINUE WHEN v_name IS NULL;
        IF v_s->>'kind' = 'household' THEN
            v_house := v_house || jsonb_build_array(jsonb_build_object('name', v_name, 'amount', v_s->'amount'));
            CONTINUE;
        END IF;
        v_nc := finance.fn_recurring_name_check(v_name);
        IF (v_nc->>'ok')::boolean IS DISTINCT FROM true THEN
            v_hints := v_hints || jsonb_build_array(jsonb_build_object('kind', 'name_taken', 'name', v_name));
            CONTINUE;
        END IF;
        v_entity := CASE WHEN v_s->>'kind' = 'transfer' THEN 'recurring_transfer' ELSE 'recurring_payment' END;
        v_series := COALESCE(finance.fn_recurring_clean_name(v_s->>'series'), v_name);
        v_other  := CASE WHEN v_entity = 'recurring_transfer'
                         THEN CASE WHEN (v_s->>'from_account_id')::int = v_acct.id THEN (v_s->>'to_account_id')::int
                                   ELSE (v_s->>'from_account_id')::int END END;
        v_iban   := CASE WHEN v_entity = 'recurring_transfer' THEN (SELECT a.account_number FROM finance.accounts a WHERE a.id = v_other)
                         ELSE NULLIF(v_s->>'counterparty_iban', '') END;
        SELECT COALESCE(jsonb_agg(jsonb_build_object('date', d->>'date', 'amount', (d->>'amount')::numeric, 'account_id', v_acct.id,
                   'period_start', v_ps, 'period_end', v_pe) ORDER BY d->>'date'), '[]'::jsonb)
        INTO v_new FROM jsonb_array_elements(COALESCE(v_s->'dates', '[]'::jsonb)) d;
        v_pl := jsonb_strip_nulls(jsonb_build_object(
            'name', v_name, 'series', v_series, 'account_id', v_acct.id, 'recurring_kind', v_s->>'recurring_kind',
            'origin_kind', v_mode, 'amount', v_s->'amount', 'schedule_unit', v_s->>'schedule_unit',
            'schedule_interval', v_s->'schedule_interval', 'schedule_day_of_month', v_s->'schedule_day_of_month',
            'first_payment_date', v_s->>'first_payment_date', 'counterparty_iban', v_iban,
            'creditor_id', v_s->>'creditor_id', 'mandate_ref', v_s->>'mandate_ref',
            'rhythm_hint', CASE WHEN v_s->>'schedule_unit' = 'year' THEN 'yearly'
                                WHEN v_s->>'schedule_unit' = 'month' AND (v_s->>'schedule_interval')::int = 3 THEN 'quarterly'
                                WHEN v_s->>'schedule_unit' = 'month' AND (v_s->>'schedule_interval')::int = 6 THEN 'half_yearly'
                                WHEN v_s->>'schedule_unit' = 'month' THEN 'monthly' END,
            'direction', CASE WHEN v_entity = 'recurring_payment' THEN v_s->>'direction' END,
            'account', CASE WHEN v_entity = 'recurring_payment' THEN v_acct.name END,
            'from_account_id', v_s->'from_account_id', 'to_account_id', v_s->'to_account_id',
            'from_account', v_s->>'from_account', 'to_account', v_s->>'to_account'))
            || jsonb_build_object('occurrences', v_new);

        SELECT s.* INTO v_row FROM finance.import_staging s
        WHERE s.batch_id = v_batch AND s.origin = 'recurring_suggestion' AND s.entity_type = v_entity
          AND (s.payload->>'account_id')::int = v_acct.id
          AND s.payload->>'direction' IS NOT DISTINCT FROM v_pl->>'direction'
          AND NOT (v_iban IS NOT NULL AND s.payload->>'counterparty_iban' IS NOT NULL AND s.payload->>'counterparty_iban' <> v_iban)
          AND ( (v_iban IS NOT NULL AND s.payload->>'counterparty_iban' = v_iban)
             OR (v_pl ? 'mandate_ref' AND s.payload->>'creditor_id' = v_pl->>'creditor_id' AND s.payload->>'mandate_ref' = v_pl->>'mandate_ref')
             OR lower(s.payload->>'series') = lower(v_series)
             OR lower(s.payload->>'name') = lower(v_name))
        ORDER BY (s.status = 'staged') DESC, s.id
        LIMIT 1 FOR UPDATE;

        IF v_row.id IS NOT NULL THEN
            CONTINUE WHEN v_row.status = 'committed';
            -- gleicher Zeitraum desselben Kontos = derselbe Auszug noch einmal: seine Termine ersetzen
            SELECT COALESCE(jsonb_agg(x.o ORDER BY x.o->>'date'), '[]'::jsonb) INTO v_occ
            FROM (SELECT DISTINCT ON (o->>'date', (o->>'amount')::numeric) o
                  FROM (SELECT o FROM jsonb_array_elements(COALESCE(v_row.payload->'occurrences', '[]'::jsonb)) o
                        WHERE NOT ((o->>'account_id')::int = v_acct.id
                                   AND (o->>'period_start') IS NOT DISTINCT FROM v_ps::text
                                   AND (o->>'period_end') IS NOT DISTINCT FROM v_pe::text)
                        UNION ALL SELECT o FROM jsonb_array_elements(v_new) o) u
                  ORDER BY o->>'date', (o->>'amount')::numeric, (o->>'period_end') DESC NULLS LAST) x;
            IF v_row.status = 'declined' THEN
                UPDATE finance.import_staging SET payload = jsonb_set(payload, '{occurrences}', v_occ), merged_at = now()
                WHERE id = v_row.id;
            ELSIF (SELECT array_agg((o->>'date') || '|' || ((o->>'amount')::numeric)::text ORDER BY o->>'date', (o->>'amount')::numeric)
                   FROM jsonb_array_elements(v_occ) o)
                  IS DISTINCT FROM
                  (SELECT array_agg((o->>'date') || '|' || ((o->>'amount')::numeric)::text ORDER BY o->>'date', (o->>'amount')::numeric)
                   FROM jsonb_array_elements(COALESCE(v_row.payload->'occurrences', '[]'::jsonb)) o) THEN
                v_pl := jsonb_set(v_row.payload, '{occurrences}', v_occ);
                v_m := finance.fn_recurring_suggestion_measure(v_pl);
                IF v_m IS NOT NULL THEN
                    v_pl := v_pl || jsonb_strip_nulls(jsonb_build_object('amount', v_m->'amount', 'schedule_unit', v_m->>'schedule_unit',
                                'schedule_interval', v_m->'schedule_interval', 'first_payment_date', v_m->>'first_payment_date'))
                            || jsonb_build_object('schedule_day_of_month', v_m->'schedule_day_of_month');
                END IF;
                UPDATE finance.import_staging SET payload = v_pl, version = version + 1, merged_at = now()
                WHERE id = v_row.id;
            ELSE
                UPDATE finance.import_staging SET payload = jsonb_set(payload, '{occurrences}', v_occ), merged_at = now()
                WHERE id = v_row.id;
            END IF;
            v_updated := v_updated + 1;
        ELSE
            -- Name im Stapel eindeutig (zwei Reihen mit gleichem Namen, aber verschiedener IBAN)
            v_n := 1;
            WHILE EXISTS (SELECT 1 FROM finance.import_staging s WHERE s.batch_id = v_batch AND lower(s.payload->>'name') = lower(v_pl->>'name')) LOOP
                v_n := v_n + 1;
                v_pl := jsonb_set(v_pl, '{name}', to_jsonb(left(v_name, 37) || ' ' || v_n));
            END LOOP;
            INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, status, source, origin, chat_id, version, merged_at)
            VALUES (v_batch, COALESCE((SELECT max(row_no) FROM finance.import_staging WHERE batch_id = v_batch), 0) + 1,
                    v_entity, v_pl, 'staged', v_src, 'recurring_suggestion', v_chat, 1, now());
            v_staged := v_staged + 1;
        END IF;
    END LOOP;

    -- ---------- Zusammenfassung des offenen Stapels ----------
    SELECT count(*) FILTER (WHERE (finance.fn_recurring_suggestion_measure(s.payload)->>'confidence') = 'sure'),
           count(*) FILTER (WHERE (finance.fn_recurring_suggestion_measure(s.payload)->>'confidence') = 'confirm')
    INTO v_sure, v_conf
    FROM finance.import_staging s WHERE s.batch_id = v_batch AND s.status = 'staged';
    IF v_mode = 'statement' AND v_pe IS NOT NULL THEN
        SELECT array_agg(DISTINCT to_char(m, 'YYYY-MM')) INTO v_seen
        FROM (SELECT (o->>'period_start')::date AS ps, (o->>'period_end')::date AS pe
              FROM finance.import_staging s, jsonb_array_elements(s.payload->'occurrences') o
              WHERE s.batch_id = v_batch AND (o->>'account_id')::int = v_acct.id AND NULLIF(o->>'period_start', '') IS NOT NULL
              UNION SELECT COALESCE(v_ps, v_pe), v_pe) pr
        CROSS JOIN LATERAL generate_series(date_trunc('month', pr.ps), date_trunc('month', pr.pe), interval '1 month') m;
        SELECT array_agg(to_char(m, 'YYYY-MM') ORDER BY m) INTO v_target
        FROM generate_series(date_trunc('month', (SELECT max(to_date(x, 'YYYY-MM')) FROM unnest(v_seen) x)) - interval '2 months',
                             date_trunc('month', (SELECT max(to_date(x, 'YYYY-MM')) FROM unnest(v_seen) x)), interval '1 month') m;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object('ok', true, 'account_name', v_acct.name, 'hint', v_hint))
        || jsonb_build_object(
            'staged', v_staged, 'updated', v_updated,
            'open_count', (SELECT count(*) FROM finance.import_staging s WHERE s.batch_id = v_batch AND s.status = 'staged'),
            'unsent_count', (SELECT count(*) FROM finance.import_staging s WHERE s.batch_id = v_batch AND s.status = 'staged'
                               AND s.sent_version IS DISTINCT FROM s.version),
            'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object('nr', s.row_no, 'name', s.payload->>'name') ORDER BY s.row_no)
                              FROM finance.import_staging s WHERE s.batch_id = v_batch AND s.status = 'staged'), '[]'::jsonb),
            'sure_count', v_sure, 'confirm_count', v_conf,
            'hints', v_hints, 'household', v_house, 'known_elsewhere', v_elsewh,
            'months_seen', to_jsonb(COALESCE((SELECT array_agg(x ORDER BY x) FROM unnest(v_seen) x), '{}'::text[])),
            'months_missing', to_jsonb(COALESCE((SELECT array_agg(t ORDER BY t) FROM unnest(v_target) t WHERE NOT (t = ANY(v_seen))), '{}'::text[])));
END;
$$;
