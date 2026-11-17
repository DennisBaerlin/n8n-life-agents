-- tests/db/estate/test_prop_case_change_vs_fresh.sql
-- Eigenschafts-Test der Fristen eines Ereignisfalls: eine Aenderung gegen den frisch angelegten Fall.
--   F1 Fall aendern (Kenntnis-Datum, Bundesland) ergibt dieselben Aufgaben, Fristen und Status wie ein Fall, der
--      gleich mit den neuen Werten angelegt wird
--   F2 Aendern und Zurueckaendern ergibt die Fristen des Ausgangszustands
--   F3 Werktags-Frist (fn_add_business_days): das Ergebnis ist ein Werktag (Mo-Fr, kein Feiertag des Landes), zwischen
--      Start und Ergebnis liegen genau n Werktage, und add(add(d, a), b) = add(d, a + b)
-- Jeder Fall in einem eigenen Savepoint (je Person ist nur ein offener Fall erlaubt). Personen und Daten erfunden.
BEGIN;

CREATE FUNCTION pg_temp.case_sig(p_case bigint) RETURNS text LANGUAGE sql AS $f$
  SELECT string_agg(coalesce(t.template_key, '-') || '/' || t.subject_ref || '=' || coalesce(t.due_date::text, 'null') || ':' || t.status, ','
                    ORDER BY t.template_key, t.subject_ref)
  FROM estate.case_tasks t WHERE t.case_id = p_case;
$f$;

DO $$
DECLARE
  v_r JSONB; v_case BIGINT; v_fresh TEXT; v_orig TEXT; v_sig TEXT;
  v_events DATE[] := ARRAY['2024-01-15','2024-03-27','2024-12-20','2025-04-16','2025-10-29']::date[];
  v_lands  TEXT[] := ARRAY['bayern','berlin','sachsen'];
  v_e DATE; v_l1 TEXT; v_l2 TEXT; v_k INT; v_n INT := 0; v_nb INT := 0;
  v_d DATE; v_a INT; v_b INT; v_res DATE; v_cnt INT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','mia','first_name','Mia','last_name','Test','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','ole','first_name','Ole','last_name','Test','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  FOREACH v_e IN ARRAY v_events LOOP
    FOREACH v_l1 IN ARRAY v_lands LOOP
      FOREACH v_l2 IN ARRAY v_lands LOOP
        FOREACH v_k IN ARRAY ARRAY[0, 3, 20] LOOP
          CONTINUE WHEN v_l1 = v_l2 AND v_k = 0;
          -- Soll: frisch mit den Zielwerten
          BEGIN
            v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','ole',
              'event_date',v_e,'knowledge_date',v_e + v_k,'bundesland',v_l2));
            IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL F setup frisch: %', v_r; END IF;
            v_fresh := pg_temp.case_sig((v_r->>'case_id')::bigint);
            RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
          EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
          END;
          -- Ist: mit Ausgangswerten anlegen, dann aendern
          BEGIN
            v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','ole',
              'event_date',v_e,'knowledge_date',v_e,'bundesland',v_l1));
            IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL F setup: %', v_r; END IF;
            v_case := (v_r->>'case_id')::bigint;
            v_orig := pg_temp.case_sig(v_case);
            v_r := estate.fn_set_case(jsonb_build_object('chat_id','111','case_id',v_case,'knowledge_date',v_e + v_k,'bundesland',v_l2));
            IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL F1 set_case: %', v_r; END IF;
            v_sig := pg_temp.case_sig(v_case);
            IF v_sig IS DISTINCT FROM v_fresh THEN
              RAISE EXCEPTION 'FAIL F1 [Ereignis % Kenntnis +% Land % -> %]: geaendert % frisch %', v_e, v_k, v_l1, v_l2, v_sig, v_fresh; END IF;
            v_r := estate.fn_set_case(jsonb_build_object('chat_id','111','case_id',v_case,'knowledge_date',v_e,'bundesland',v_l1));
            IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL F2 set_case zurueck: %', v_r; END IF;
            IF pg_temp.case_sig(v_case) IS DISTINCT FROM v_orig THEN
              RAISE EXCEPTION 'FAIL F2 [Ereignis % Kenntnis +% Land % -> % -> zurueck]: % statt %', v_e, v_k, v_l1, v_l2, pg_temp.case_sig(v_case), v_orig; END IF;
            v_n := v_n + 1;
            RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
          EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
          END;
        END LOOP;
      END LOOP;
    END LOOP;
  END LOOP;

  -- F3: jeden 5. Tag von 2027 und 2028, drei Laender
  FOREACH v_l1 IN ARRAY v_lands LOOP
    FOR v_k IN 0..730 BY 5 LOOP
      v_d := DATE '2027-01-01' + v_k;
      FOREACH v_a IN ARRAY ARRAY[1, 3, 7] LOOP
        v_res := estate.fn_add_business_days(v_d, v_a, v_l1);
        SELECT count(*) INTO v_cnt FROM generate_series(v_d + 1, v_res, interval '1 day') g
         WHERE EXTRACT(isodow FROM g)::int < 6 AND NOT (g::date = ANY (estate.fn_public_holidays(EXTRACT(year FROM g)::int, v_l1)));
        IF v_res <= v_d OR EXTRACT(isodow FROM v_res)::int > 5 OR v_res = ANY (estate.fn_public_holidays(EXTRACT(year FROM v_res)::int, v_l1)) OR v_cnt <> v_a THEN
          RAISE EXCEPTION 'FAIL F3 [% + % Werktage, %]: % (Werktage dazwischen %)', v_d, v_a, v_l1, v_res, v_cnt; END IF;
        v_b := 2;
        IF estate.fn_add_business_days(v_res, v_b, v_l1) IS DISTINCT FROM estate.fn_add_business_days(v_d, v_a + v_b, v_l1) THEN
          RAISE EXCEPTION 'FAIL F3 [% + % + %, %]: nicht additiv', v_d, v_a, v_b, v_l1; END IF;
        v_nb := v_nb + 1;
      END LOOP;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'PASS prop case change vs fresh [F1/F2: % Aenderungen, F3: % Werktags-Fristen]', v_n, v_nb;
END $$;

ROLLBACK;
