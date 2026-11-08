-- tests/db/estate/pending_drift_findings.sql
-- PENDING: Drift-Funde (Prompt/Tool-Description <-> fn-Vertrag) im Nachlass-Paket, bewusst ROT und ausserhalb des
-- Gates (db_test sammelt nur test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_drift_*'
-- Fund-Nummern = Karten-IDs im Drift-Bericht (S<Stufe>.<n>, Stand main 8ff7de43). Eine Transaktion je Fall.

-- (S2.1) Ernstfall: Die trauernde Person nennt eine Waffe. Der Prompt laesst einmal nach Fahrzeug/Firma/Waffe/Haustier
--   fragen ("they change the checklist") und dann tool_create_case rufen - das Tool hat dafuer kein Feld, die
--   Pflicht-Aufgabe entsteht nur per fan_out aus estate.special_assets. Der heutige Umweg (special_asset anlegen, dann
--   fn_set_case) funktioniert (test_fn_set_case: fan_out), steht aber in keinem Prompt-Ablauf.
--   Korrekt (Fix-Idee b, DB-Gesetz): fn_create_case nimmt genannte Sonderfaelle mit (special_assets[]) und legt die
--   Stubs in derselben Tx an -> Aufgabe "Waffe" offen. Bleibt es bei Fix-Idee a (Prompt-Ablauf), diesen Fall loeschen
--   und stattdessen den Golden-Case "Tod + Waffe genannt" bauen.
BEGIN;
DO $$
DECLARE v_r jsonb; v_case bigint; v_cnt int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM estate.special_assets WHERE owner_person_id = 'hans' OR owner_person_id IS NULL;
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description','Beispiel-Jagdwaffe'))));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [S2.1] %', v_r; END IF;
  v_case := (v_r->>'case_id')::bigint;
  SELECT count(*) INTO v_cnt FROM estate.case_tasks t WHERE t.case_id = v_case AND t.status = 'open' AND t.subject_ref LIKE 'asset:%';
  IF v_cnt = 0 THEN
    RAISE EXCEPTION 'FAIL [S2.1] im Gespraech genannte Waffe ohne offene Pflicht-Aufgabe (create_case hat kein Eingabefeld), got %', v_r;
  END IF;
  RAISE NOTICE 'PASS [S2.1]';
END $$;
ROLLBACK;
