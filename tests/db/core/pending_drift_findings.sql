-- tests/db/core/pending_drift_findings.sql
-- PENDING: Drift-Funde (Tool-Description <-> fn-Vertrag) im Core, bewusst ROT und ausserhalb des Gates
-- (db_test sammelt nur test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_drift_*'
-- Fund-Nummern = Karten-IDs im Drift-Bericht (S<Stufe>.<n>, Stand main 8ff7de43). Jeder Fall prueft das KORREKTE
-- Verhalten; nach dem Fix in die passende test_fn_*.sql verschieben. Eine Transaktion je Fall.

-- (S2.7) Termin-Erinnerung mit Monats-Rhythmus: date-Trigger feuert nur, wenn ein Pruefslot ansteht; fn_next_check
--   rueckt um das volle Intervall vor, ohne an due_date zu kappen. Frist in 10 Tagen, Rhythmus 1 Monat: der erste
--   Lauf (morgen) schiebt den naechsten Slot hinter die Frist, am Fristtag feuert nichts.
--   Korrekt: am Fristtag (im Erinnerungsfenster) gefeuert. Fix-Idee: next_check_at fuer date-Trigger auf
--   min(Slot, due_date - warn_days_before, due_date) kappen (Kern in fn_monitor_evaluate/fn_next_check).
BEGIN;
DO $$
DECLARE v jsonb; v_due date := CURRENT_DATE + 10; v_tz text := current_setting('TimeZone');
BEGIN
  PERFORM set_config('TimeZone', 'Europe/Berlin', true);
  v := agent.fn_create_monitor_trigger(jsonb_build_object('domain','__drift__','label','__drift_s27_frist__',
         'trigger_type','date','acquisition_method','none','due_date',v_due::text,'warn_days_before',0,
         'check_interval','1 month','action_note','Beispiel-Frist'));
  IF NOT (v->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [S2.7] %', v; END IF;
  PERFORM agent.fn_monitor_evaluate(jsonb_build_object('now', ((CURRENT_DATE + 1)::timestamp + interval '10 hours')::timestamptz));
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', (v_due::timestamp + interval '10 hours')::timestamptz));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'fired') e WHERE e->>'label' = '__drift_s27_frist__') THEN
    RAISE EXCEPTION 'FAIL [S2.7] Frist % nicht am Fristtag gefeuert; naechster Pruefslot %',
      v_due, (SELECT next_check_at FROM agent.monitor_triggers WHERE label = '__drift_s27_frist__');
  END IF;
  PERFORM set_config('TimeZone', v_tz, true);
  RAISE NOTICE 'PASS [S2.7]';
END $$;
ROLLBACK;

-- (S2.8) "Erinnere mich jeden Montag" (recurring_info, Rhythmus 7 Tage): kein Start-Feld, next_check_at DEFAULT now()
--   -> erste Meldung im naechsten Heartbeat, danach am Wochentag des Anlegens. Korrekt: ein optionales first_check
--   (Datum, ueber fn_resolve_date) setzt den Anker. Fix-Idee: first_check in fn_create_monitor_trigger, Description
--   fragt "ab wann".
BEGIN;
DO $$
DECLARE v jsonb; v_first date := CURRENT_DATE + (8 - extract(isodow FROM CURRENT_DATE)::int); v_next timestamptz;
BEGIN
  v := agent.fn_create_monitor_trigger(jsonb_build_object('domain','__drift__','label','__drift_s28_montag__',
         'trigger_type','recurring_info','acquisition_method','none','check_interval','7 days',
         'action_note','Wochenplan ansehen','first_check',v_first::text));
  IF NOT (v->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [S2.8] %', v; END IF;
  v_next := (v->>'next_check_at')::timestamptz;
  IF v_next::date IS DISTINCT FROM v_first THEN
    RAISE EXCEPTION 'FAIL [S2.8] first_check % ignoriert, next_check_at = % (Anker = Anlegezeitpunkt)', v_first, v_next;
  END IF;
  RAISE NOTICE 'PASS [S2.8]';
END $$;
ROLLBACK;

-- (S2.9) Gefeuerten Termin-Trigger "fuers naechste Jahr" wieder scharf stellen (status=armed, ohne neues Datum):
--   Re-arm setzt next_check_at = now und laesst das vergangene due_date stehen -> feuert im naechsten Lauf erneut.
--   Korrekt: {ok:false} "neues Datum nennen", solange due_date <= heute und kein due_date mitkommt.
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  v := agent.fn_create_monitor_trigger(jsonb_build_object('domain','__drift__','label','__drift_s29_frist__',
         'trigger_type','date','acquisition_method','none','due_date',(CURRENT_DATE + 5)::text,'check_interval','1 day'));
  IF NOT (v->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [S2.9] %', v; END IF;
  -- Zeitablauf simulieren: Frist vorbei, Trigger hat gefeuert
  UPDATE agent.monitor_triggers SET due_date = CURRENT_DATE - 3, status = 'fired', fired_at = now() - interval '3 days'
   WHERE label = '__drift_s29_frist__';
  v := agent.fn_set_monitor_trigger('{"domain":"__drift__","label":"__drift_s29_frist__","status":"armed"}'::jsonb);
  IF (v->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S2.9] Re-arm mit vergangenem due_date angenommen (feuert sofort wieder), erwartet ok:false, got %', v;
  END IF;
  RAISE NOTICE 'PASS [S2.9]';
END $$;
ROLLBACK;

-- (S2.10) Trigger aendern mit comparator ">=" (statt gte): fn_set_monitor_trigger behaelt still den alten Wert,
--   ok:true; die Karte zeigt alles ausser "lte" als ">=". Korrekt: {ok:false} fuer unbekannten comparator.
BEGIN;
DO $$
DECLARE v jsonb; v_cmp text;
BEGIN
  v := agent.fn_create_monitor_trigger(jsonb_build_object('domain','__drift__','label','__drift_s210_kurs__',
         'trigger_type','threshold','acquisition_method','web_search','acquisition_prompt','Beispielkurs in EUR',
         'comparator','lte','threshold_value',50,'expected_unit','EUR','check_interval','1 day'));
  IF NOT (v->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [S2.10] %', v; END IF;
  v := agent.fn_set_monitor_trigger('{"domain":"__drift__","label":"__drift_s210_kurs__","comparator":">="}'::jsonb);
  SELECT comparator INTO v_cmp FROM agent.monitor_triggers WHERE label = '__drift_s210_kurs__';
  IF (v->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S2.10] comparator ">=" still ignoriert (gespeichert %), erwartet ok:false, got %', v_cmp, v;
  END IF;
  RAISE NOTICE 'PASS [S2.10]';
END $$;
ROLLBACK;

-- (S2.11) Plan-Abschnitt mit Tippfehler im section_key ("risk_profil"): fn_advisor_save_section prueft nur "nicht
--   leer" und legt einen Phantom-Abschnitt an. Korrekt: {ok:false} mit den gueltigen Keys der Domaene.
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  v := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','plan_name','__drift_s211_plan__',
         'section_key','risk_profil','section_content','Beispiel: mittlere Risikobereitschaft.'));
  IF (v->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S2.11] unbekannter section_key "risk_profil" gespeichert, erwartet ok:false mit gueltigen Keys, got %', v;
  END IF;
  RAISE NOTICE 'PASS [S2.11]';
END $$;
ROLLBACK;

-- (S3.2) Trigger-Schwelle "1,5" (deutsches Komma, threshold_value ohne Format-Hinweis): ::numeric-Cast -> RAISE
--   (Owner-Alarm), obwohl der fn-Kopf "kein RAISE" verspricht. Korrekt: 1.5 gespeichert oder {ok:false}.
--   Fix-Idee: fn_parse_de_numeric / fn_enum_reason wie in finance.
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  BEGIN
    v := agent.fn_create_monitor_trigger(jsonb_build_object('domain','__drift__','label','__drift_s32_zins__',
           'trigger_type','threshold','acquisition_method','web_search','acquisition_prompt','Beispiel-Zinssatz in Prozent',
           'comparator','gte','threshold_value','1,5','expected_unit','%','min_plausible','0','max_plausible','20',
           'check_interval','1 day'));
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'FAIL [S3.2] threshold_value "1,5" -> RAISE (%), erwartet 1.5 oder ok:false', SQLERRM;
  END;
  RAISE NOTICE 'PASS [S3.2] %', v;
END $$;
ROLLBACK;

-- (S3.12) Partnerin hakt einen Finanz-Onboarding-Bereich ab (finance/estate sind household-Bereiche): Antwort ist der
--   nackte Code reason='owner_only', keine Description erklaert ihn. Korrekt: ein englischer Satz mit naechstem Schritt
--   ("only the owner can mark ..."). Fix-Idee: Satz in der fn, ein Halbsatz in den Descriptions.
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner',
                               'birth_date','1980-05-20','telegram_user_id',111),
            jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel','role','partner',
                               'birth_date','1985-06-21','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  v := core.fn_set_onboarding_section('{"package":"finance","section_key":"accounts","status":"completed","chat_id":"222"}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'SETUP [S3.12] Ablehnung erwartet, got %', v; END IF;
  IF v->>'reason' !~ ' ' THEN
    RAISE EXCEPTION 'FAIL [S3.12] Ablehnung nur als Code "%", erwartet Satz mit naechstem Schritt, got %', v->>'reason', v;
  END IF;
  RAISE NOTICE 'PASS [S3.12]';
END $$;
ROLLBACK;
