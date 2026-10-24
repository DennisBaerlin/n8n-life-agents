-- tests/db/estate/test_fn_advisor_review.sql
-- WS-4 (Plan groovy-watching-wave): estate.fn_advisor_review — der paket-besessene Jahres-Review der
-- generischen Core-Advisor-Engine (Registry-Dispatch via core.fn_advisor_review_evaluate). estate ist
-- HAUSHALT (p_person_id ignoriert, NULL byte-gleich; NICHT per_user wie career). Prueft:
--   (A) STALENESS je Erwachsenem: person_records.last_reviewed_at > advisor.estate_review_days (365)
--       -> ein Alert je ueberfaelligem Erwachsenen (metric_key review_staleness:<pid>); frischer
--       Review -> KEIN Alert; NULL last_reviewed_at (nie bestaetigt) -> KEIN Alert (Analog-treu: keine
--       "Frist gerissen"-Basis; die Register-Luecke deckt Unvollstaendigkeit ab).
--   (B) FEHLENDE Vorsorge-Dokumente je Erwachsenem (aus v_directive_gaps, essential+recommended) ->
--       ein Alert je Erwachsenem mit Luecken (metric_key directive_gaps:<pid>); alle gedeckt -> 0.
--   (C) finance-Nachlass-Feld-Gaps GUARDED (aus estate.fn_gap_report -> doppel-guardet): finance aktiv +
--       Police/Konto mit offenen Nachlass-Feldern -> ein Singleton-Alert finance_gaps;
--       finance ABSENT -> KEIN Alert, KEIN Crash (graceful degradation).
--   (D) DIGEST-Paritaet zum Analog: der digest traegt seinen VOLLEN Satz strukturierter Felder (estate-
--       spezifisch, NICHT finance's 12) + das paket-gerenderte 'text'-Feld (Generik-Vertrag) — voller
--       Regressionsnetz-Assert wie der finance-Digest-Test. RAISE-FREI (der ganze DO-Block laeuft durch).
--   (E) EMPIRISCHER Scope-Fan-out (Opus-M5): estate_overview hat KEINE core.context_scopes-Zeile ->
--       agent.fn_context_persons('estate_overview') ist LEER -> die Eval-Faecherung laeuft household
--       (person_id NULL), NIE per_user-suffigiert. PLUS Kern-Engine-Latch: core.fn_advisor_review_evaluate
--       ('estate', NULL, '{}') dispatcht -> send-once (Erst-Breach) -> still (gelatcht).
-- Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  r          jsonb;
  w          jsonb;
  v_dig      jsonb;
  v_n        int;
  v_key      text;
BEGIN
  -- ---------- Fixture: 2 Erwachsene + 1 Kind (family projiziert -> agent.persons) ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ============================================================
  -- (0) Roter Faden "erst einladen, dann mahnen": estate nicht begonnen (kein Abschnitt completed) -> 0 Alerts,
  --     auch wenn Luecken bestehen; nur 'skipped' zaehlt ebenfalls nicht als begonnen. Danach: begonnen.
  -- ============================================================
  INSERT INTO estate.person_records (person_id, last_reviewed_at) VALUES
    ('erika', now() - interval '400 days'),   -- ueberfaellig (> 365)
    ('lena',  now());                          -- frisch bestaetigt
  DELETE FROM estate.onboarding_state;
  INSERT INTO estate.onboarding_state (section_key, ord, label, status) VALUES
    ('documents', 1, 'Dokumente', 'skipped'), ('contacts', 2, 'Kontakte', 'unknown');
  r := estate.fn_advisor_review('estate');
  IF jsonb_array_length(r->'alerts') <> 0 THEN
    RAISE EXCEPTION 'FAIL [0 nicht begonnen -> 0 Alerts]: %', r->'alerts'; END IF;
  IF r->'digest' IS NULL THEN RAISE EXCEPTION 'FAIL [0 Digest bleibt]'; END IF;
  UPDATE estate.onboarding_state SET status = 'completed' WHERE section_key = 'documents';
  RAISE NOTICE 'PASS [0] nicht begonnen -> keine Mahnung; Digest bleibt';

  -- ============================================================
  -- (A) STALENESS je Erwachsenem
  -- ============================================================
  r := estate.fn_advisor_review('estate');

  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'staleness';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [A staleness count]: % Alert(s) statt 1 (alerts=%)', v_n, r->'alerts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'review_staleness:erika'
                   AND COALESCE((a->'msg')::text,'') <> '' AND (a->'msg')::text LIKE '%400%') THEN
    RAISE EXCEPTION 'FAIL [A erika-staleness key/text]: %', r->'alerts'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
             WHERE a->>'metric_key' = 'review_staleness:lena') THEN
    RAISE EXCEPTION 'FAIL [A frischer Review von lena darf NICHT feuern]'; END IF;
  RAISE NOTICE 'PASS [A] Staleness feuert per ueberfaelligem Erwachsenen, nicht bei frischem Review';

  -- Grenze: NULL last_reviewed_at (nie bestaetigt) feuert KEINE Staleness (keine gerissene Frist).
  UPDATE estate.person_records SET last_reviewed_at = NULL WHERE person_id = 'erika';
  r := estate.fn_advisor_review('estate');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'staleness';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [A NULL-Grenze]: NULL last_reviewed_at feuerte Staleness (%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [A] NULL last_reviewed_at feuert keine Staleness (Analog-treu)';

  -- ============================================================
  -- (B) FEHLENDE Vorsorge-Dokumente je Erwachsenem
  -- ============================================================
  -- Register leer -> beide Erwachsene haben Dokument-Luecken (essential+recommended = 5 je Person).
  r := estate.fn_advisor_review('estate');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'directive_gap';
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [B directive_gap count]: % statt 2 (je Erwachsenem einer)', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'directive_gaps:erika'
                   AND (a->'msg')::text LIKE '%Testament%') THEN
    RAISE EXCEPTION 'FAIL [B erika directive-gap key/essential-Text]: %', r->'alerts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'directive_gaps:lena') THEN
    RAISE EXCEPTION 'FAIL [B lena directive-gap key fehlt]: %', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [B] Dokument-Luecke feuert je Erwachsenem mit essential-Nennung';

  -- Alle essential+recommended als Haushalts-Urkunde 'exists' -> beide Erwachsene gedeckt -> 0 Alerts.
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES
    (NULL, 'testament', 'exists'),
    (NULL, 'vorsorgevollmacht', 'exists'),
    (NULL, 'patientenverfuegung', 'exists'),
    (NULL, 'bankvollmacht_transmortal', 'exists'),
    (NULL, 'betreuungsverfuegung', 'exists');
  r := estate.fn_advisor_review('estate');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'directive_gap';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [B Deckung]: directive_gap trotz vollstaendiger Haushalts-Urkunden (% Alerts)', v_n; END IF;
  RAISE NOTICE 'PASS [B] vollstaendige Erwartungsmenge -> 0 Dokument-Luecken-Alerts (Re-Arm-Pfad)';

  -- ============================================================
  -- (C) finance-Nachlass-Gaps GUARDED + graceful ohne finance
  -- ============================================================
  -- finance NICHT registriert -> fn_gap_report finance.status='absent' -> KEIN Alert, KEIN Crash.
  r := estate.fn_advisor_review('estate');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'finance_gap';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [C graceful ohne finance]: finance_gap-Alert trotz absentem finance (%)', v_n; END IF;
  IF (r->'digest'->>'finance_status') <> 'absent' THEN
    RAISE EXCEPTION 'FAIL [C finance_status]: % statt absent', r->'digest'->>'finance_status'; END IF;
  RAISE NOTICE 'PASS [C] finance absent -> kein finance-Alert, digest finance_status=absent (graceful)';

  -- finance aktiv + Police/Konto mit offenen Nachlass-Feldern -> Singleton finance_gaps.
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO finance.insurances (name, annual_premium, schedule_unit, valid_from, insurance_type)
  VALUES ('__test__ Risikoleben', 240, 'year', CURRENT_DATE, 'life');       -- beneficiary/policy/claim fehlen
  INSERT INTO finance.accounts (name, account_type) VALUES ('__test__ Giro', 'cash');  -- ownership/poa offen
  r := estate.fn_advisor_review('estate');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'finance_gap';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [C finance_gap Singleton]: % statt 1 (alerts=%)', v_n, r->'alerts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'finance_gaps'
                   AND COALESCE((a->'msg')::text,'') <> '' AND (a->'msg')::text LIKE '%Risikoleben%') THEN
    RAISE EXCEPTION 'FAIL [C finance_gap key/text]: %', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [C] finance aktiv + offene Nachlass-Felder -> Singleton finance_gaps (guarded)';

  -- ============================================================
  -- (D) DIGEST-Paritaet + RAISE-frei
  -- ============================================================
  v_dig := r->'digest';
  IF jsonb_typeof(v_dig) <> 'object' THEN RAISE EXCEPTION 'FAIL [D digest kein Objekt]: %', v_dig; END IF;
  IF COALESCE((v_dig->'lines')::text,'') = '' THEN RAISE EXCEPTION 'FAIL [D digest.text leer]: %', v_dig; END IF;
  -- Voller strukturierter Feld-Satz (Regressionsnetz wie der finance-12-Feld-Assert; estate-spezifisch):
  FOR v_key IN SELECT unnest(ARRAY['adults_total','reviews_recorded','stale_review_count',
                                   'directive_gap_count','register_gap_count','finance_gap_count',
                                   'finance_status','lines'])
  LOOP
    IF NOT (v_dig ? v_key) THEN RAISE EXCEPTION 'FAIL [D digest-Feld % fehlt]: %', v_key, v_dig; END IF;
  END LOOP;
  IF (v_dig->>'adults_total')::int <> 2 THEN RAISE EXCEPTION 'FAIL [D adults_total]: % statt 2', v_dig->>'adults_total'; END IF;
  -- finance_gap_count zaehlt die betroffenen finance-EINTRAEGE (Police + Konto = 2), NICHT die Alerts
  -- (der finance_gaps-Alert ist EIN Singleton mit value=2 — Section C oben).
  IF (v_dig->>'finance_gap_count')::int <> 2 THEN RAISE EXCEPTION 'FAIL [D finance_gap_count]: % statt 2 (Police+Konto)', v_dig->>'finance_gap_count'; END IF;
  IF (v_dig->>'finance_status') <> 'ok' THEN RAISE EXCEPTION 'FAIL [D finance_status ok]: %', v_dig->>'finance_status'; END IF;
  RAISE NOTICE 'PASS [D] Digest traegt vollen strukturierten Feld-Satz + gerenderten text';

  -- ============================================================
  -- (E) Empirischer Scope-Fan-out (household) + Kern-Engine-Latch
  -- ============================================================
  IF EXISTS (SELECT 1 FROM agent.fn_context_persons('estate_overview')) THEN
    RAISE EXCEPTION 'FAIL [E household]: fn_context_persons(estate_overview) NICHT leer -> Fan-out suffigierte per_user'; END IF;

  -- Registry-Zeile (im db_test-Substrat nicht geseedet -> hier setzen), dann der generische Wrapper.
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package)
  VALUES ('estate', 'estate_overview', 'estate.fn_advisor_review', 'agent.estate_advisor', 'estate')
  ON CONFLICT (domain) DO UPDATE SET review_fn = EXCLUDED.review_fn, plan_context = EXCLUDED.plan_context;

  w := core.fn_advisor_review_evaluate('estate', NULL, '{}'::jsonb);
  IF NOT (w->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [E wrapper ok]: %', w; END IF;
  IF NOT (w->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [E Erst-Breach send=true]: %', w; END IF;
  w := core.fn_advisor_review_evaluate('estate', NULL, '{}'::jsonb);
  IF (w->>'send')::boolean THEN RAISE EXCEPTION 'FAIL [E gelatcht: 2. Lauf send=false erwartet]: %', w; END IF;
  RAISE NOTICE 'PASS [E] household-Fan-out (person_id NULL) + Engine-Latch send-once (Opus-M5)';

  -- ============================================================
  -- (F) Digest-Vollstaendigkeit ehrt AUCH register_gaps (Cold-Eyes WS-4)
  -- ============================================================
  -- Nur REGISTER-Luecken offen (Bestattungswuensche fehlen beiden Erwachsenen): staleness=0 (erika NULL,
  -- lena frisch), directive=0 (Haushalts-Urkunden decken beide), finance INAKTIV -> finance_gap=0. register_gaps
  -- emittieren KEINEN Alert (nur Digest-Zaehler) -> der Schluss-Satz darf dann NICHT "vollstaendig/nichts zu tun"
  -- behaupten, obwohl er "Offene Register-Luecken: N" listet.
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  r := estate.fn_advisor_review('estate');
  IF (r->'digest'->>'register_gap_count')::int = 0 THEN
    RAISE EXCEPTION 'FAIL [F Fixture]: register_gap_count 0 -> Szenario nicht register-only'; END IF;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'alerts') a
    WHERE a->>'kind' IN ('staleness', 'directive_gap', 'finance_gap');
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [F Fixture]: unerwartete Alerts (%) -> nicht register-only', r->'alerts'; END IF;
  IF (r->'digest'->'lines')::text LIKE '%estate.advisor.digest_all_done%' THEN
    RAISE EXCEPTION 'FAIL [F]: Digest behauptet "vollstaendig/nichts zu tun" trotz offener Register-Luecken: %', (r->'digest'->'lines')::text; END IF;
  IF (r->'digest'->'lines')::text NOT LIKE '%estate.advisor.digest_next%' THEN
    RAISE EXCEPTION 'FAIL [F]: Digest-Nudge "arbeiten sollen" fehlt trotz offener Luecken: %', (r->'digest'->'lines')::text; END IF;
  RAISE NOTICE 'PASS [F] Digest-Vollstaendigkeit ehrt register_gaps (kein Widerspruch)';
END $$;

ROLLBACK;
