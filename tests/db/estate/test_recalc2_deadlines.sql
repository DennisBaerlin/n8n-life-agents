-- tests/db/estate/test_recalc2_deadlines.sql
-- Zweitrechnung Runde 2, Nachlass: Fristen und Feiertage. Erwartungen von Hand am Kalender hergeleitet
-- (Wochentag ueber Tag-im-Jahr: 01.01.2027 = Freitag), nicht aus der fn abgeschrieben. Werte erfunden.
-- Fachregeln:
--   * § 28 PStG: Sterbefall "spaetestens am dritten auf den Tod folgenden Werktag"; Todestag zaehlt nicht (§ 187 Abs. 1
--     BGB); Samstag gilt in der Standesamts-Praxis nicht als Werktag (z. B. https://www.stuttgart.de/organigramm/leistungen/sterbefall-anzeigen).
--   * § 1944 Abs. 1 BGB Ausschlagung 6 Wochen ab Kenntnis; § 188 Abs. 2 BGB: Ende am gleichnamigen Wochentag.
--   * § 30 ErbStG Anzeige 3 Monate ab Kenntnis; § 188 Abs. 3 BGB: fehlt der Tag im Zielmonat, letzter Tag des Monats.
--   * § 193 BGB (Verschiebung auf den naechsten Werktag) laut fn-Kopf bewusst NICHT angewandt (fruehere Frist).
--   * Ostersonntag (Tabellenwerte): 1981-04-19, 2027-03-28, 2038-04-25 (spaetestmoeglich), 2049-04-18 (Sonderfall der
--     Gauss-Formel); Karfreitag = Ostern - 2, Ostermontag + 1, Himmelfahrt + 39, Pfingstmontag + 50, Fronleichnam + 60.
--   * Buss- und Bettag (nur Sachsen) = Mittwoch vor dem 23.11.: 2027 -> 17.11. (22.11.2027 ist ein Montag),
--     2028 -> 22.11. (selbst ein Mittwoch).
--   (1) Tod Mi 24.03.2027 (vor Ostern): Do 25. = 1, Karfreitag 26., Sa/So, Ostermontag 29., Di 30. = 2, Mi 31. = 3
--       -> 31.03.2027.
--   (2) Tod Do 28.10.2027: Fr 29. = 1; Mo 01.11. Allerheiligen nur in Bayern -> Bayern Di 2. = 2, Mi 3. = 3 -> 03.11.;
--       Berlin Mo 1. = 2, Di 2. = 3 -> 02.11.
--   (3) Tod Mo 15.11.2027: Sachsen Di 16. = 1, Mi 17. Bettag, Do 18. = 2, Fr 19. = 3 -> 19.11.; Bayern -> 18.11.
--   (4) Tod Mi 22.12.2027: Do 23. = 1, Fr 24. = 2 (Heiligabend kein Feiertag), Sa 25./So 26. -> Mo 27. = 3 -> 27.12.
--       Tod Mi 29.12.2027: Do 30. = 1, Fr 31. = 2, Sa 01.01., So, Mo 03.01.2028 = 3 -> 03.01.2028 (Jahreswechsel).
--   (5) Ausschlagung: Kenntnis Mi 10.03.2027 + 6 Wochen -> Mi 21.04.2027.
--   (6) Erbschaftsteuer-Anzeige: Kenntnis 30.11.2027 + 3 Monate -> 29.02.2028 (Schaltjahr); 30.11.2028 -> 28.02.2029;
--       Waffe 1 Monat ab 31.01.2027 -> 28.02.2027.
--   (7) Ostern-Sonderjahre: Karfreitag 17.04.1981 / 16.04.2049, Ostermontag 19.04.2049; 2038: Himmelfahrt 03.06.,
--       Pfingstmontag 14.06., Fronleichnam (NRW) 24.06.
--   (8) Fall-Vorlage "death": Tod 24.03.2027, Kenntnis 26.03.2027, Bayern -> Sterbefallanzeige 31.03. (Ereignis-Anker),
--       Ausschlagung 26.03. + 42 = 07.05.2027 (Kenntnis-Anker), Erbschaftsteuer 26.06.2027.
--   (9) Register-Review (Advisor): aelter als 365 Tage ueberfaellig -> 365 Tage alt kein Alert, 366 Tage alt Alert.
BEGIN;

DO $$
DECLARE
  r jsonb; v_due date;
BEGIN
  IF estate.fn_add_business_days('2027-03-24', 3, 'bayern') IS DISTINCT FROM DATE '2027-03-31' THEN
    RAISE EXCEPTION 'FAIL [1] Ostern: %', estate.fn_add_business_days('2027-03-24', 3, 'bayern'); END IF;
  IF estate.fn_add_business_days('2027-10-28', 3, 'bayern') IS DISTINCT FROM DATE '2027-11-03'
     OR estate.fn_add_business_days('2027-10-28', 3, 'berlin') IS DISTINCT FROM DATE '2027-11-02' THEN
    RAISE EXCEPTION 'FAIL [2] Allerheiligen: BY % / BE %', estate.fn_add_business_days('2027-10-28', 3, 'bayern'),
      estate.fn_add_business_days('2027-10-28', 3, 'berlin'); END IF;
  IF estate.fn_add_business_days('2027-11-15', 3, 'sachsen') IS DISTINCT FROM DATE '2027-11-19'
     OR estate.fn_add_business_days('2027-11-15', 3, 'bayern') IS DISTINCT FROM DATE '2027-11-18' THEN
    RAISE EXCEPTION 'FAIL [3] Bettag'; END IF;
  IF NOT (DATE '2028-11-22' = ANY (estate.fn_public_holidays(2028, 'sachsen'))) THEN
    RAISE EXCEPTION 'FAIL [3b] Bettag 2028 = 22.11.: %', estate.fn_public_holidays(2028, 'sachsen'); END IF;
  IF estate.fn_add_business_days('2027-12-22', 3, 'hessen') IS DISTINCT FROM DATE '2027-12-27'
     OR estate.fn_add_business_days('2027-12-29', 3, 'hessen') IS DISTINCT FROM DATE '2028-01-03' THEN
    RAISE EXCEPTION 'FAIL [4] Weihnachten/Jahreswechsel: % / %', estate.fn_add_business_days('2027-12-22', 3, 'hessen'),
      estate.fn_add_business_days('2027-12-29', 3, 'hessen'); END IF;
  RAISE NOTICE 'PASS [1-4] § 28 PStG: dritter Werktag ueber Ostern, Allerheiligen, Bettag, Weihnachten, Jahreswechsel';

  IF estate.fn_compute_due_date('2027-03-10', 6, 'week', 'bayern') IS DISTINCT FROM DATE '2027-04-21' THEN
    RAISE EXCEPTION 'FAIL [5] 6 Wochen'; END IF;
  IF estate.fn_compute_due_date('2027-11-30', 3, 'month', NULL) IS DISTINCT FROM DATE '2028-02-29'
     OR estate.fn_compute_due_date('2028-11-30', 3, 'month', NULL) IS DISTINCT FROM DATE '2029-02-28'
     OR estate.fn_compute_due_date('2027-01-31', 1, 'month', NULL) IS DISTINCT FROM DATE '2027-02-28' THEN
    RAISE EXCEPTION 'FAIL [6] Monatsfristen'; END IF;
  RAISE NOTICE 'PASS [5-6] Wochen- und Monatsfristen nach § 188 BGB';

  IF NOT (DATE '1981-04-17' = ANY (estate.fn_public_holidays(1981, '')))
     OR NOT (DATE '2049-04-16' = ANY (estate.fn_public_holidays(2049, '')))
     OR NOT (DATE '2049-04-19' = ANY (estate.fn_public_holidays(2049, '')))
     OR NOT (ARRAY[DATE '2038-06-03', DATE '2038-06-14', DATE '2038-06-24'] <@ estate.fn_public_holidays(2038, 'nordrhein_westfalen'))
     OR (DATE '2038-06-24' = ANY (estate.fn_public_holidays(2038, 'berlin'))) THEN
    RAISE EXCEPTION 'FAIL [7] Ostern-Sonderjahre: 1981 % / 2049 % / 2038 %', estate.fn_public_holidays(1981, ''),
      estate.fn_public_holidays(2049, ''), estate.fn_public_holidays(2038, 'nordrhein_westfalen'); END IF;
  RAISE NOTICE 'PASS [7] Osterformel in Sonderjahren 1981/2049/2038';

  SELECT due_date INTO v_due FROM estate.fn_case_template_rows('death', NULL, '{}', '2027-03-24', '2027-03-26', 'bayern') WHERE template_key = 'sterbefallanzeige';
  IF v_due IS DISTINCT FROM DATE '2027-03-31' THEN RAISE EXCEPTION 'FAIL [8a] Sterbefallanzeige: %', v_due; END IF;
  SELECT due_date INTO v_due FROM estate.fn_case_template_rows('death', NULL, '{}', '2027-03-24', '2027-03-26', 'bayern') WHERE template_key = 'inheritance_refusal';
  IF v_due IS DISTINCT FROM DATE '2027-05-07' THEN RAISE EXCEPTION 'FAIL [8b] Ausschlagung: %', v_due; END IF;
  SELECT due_date INTO v_due FROM estate.fn_case_template_rows('death', NULL, '{}', '2027-03-24', '2027-03-26', 'bayern') WHERE template_key = 'estate_tax_notice';
  IF v_due IS DISTINCT FROM DATE '2027-06-26' THEN RAISE EXCEPTION 'FAIL [8c] Erbschaftsteuer: %', v_due; END IF;
  RAISE NOTICE 'PASS [8] Fall-Vorlage: Ereignis- vs. Kenntnis-Anker';

  -- (9) Review-Grenze 365/366
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','r2a','first_name','Alex','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',811),
            jsonb_build_object('person_id','r2b','first_name','Bo','last_name','Muster','role','partner','birth_date','1982-01-01','telegram_user_id',812)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM estate.onboarding_state;
  INSERT INTO estate.onboarding_state (section_key, ord, label, status) VALUES ('documents', 1, 'Dokumente', 'completed');
  INSERT INTO estate.person_records (person_id, last_reviewed_at) VALUES
    ('r2a', (current_date - 365)::timestamptz + interval '12 hours'),
    ('r2b', (current_date - 366)::timestamptz + interval '12 hours')
  ON CONFLICT (person_id) DO UPDATE SET last_reviewed_at = EXCLUDED.last_reviewed_at;
  r := estate.fn_advisor_review('estate');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'review_staleness:r2a')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'review_staleness:r2b') THEN
    RAISE EXCEPTION 'FAIL [9] Review-Grenze 365 kein Alert / 366 Alert: %', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [9] Register-Review: 365 Tage still, 366 Tage Alert';
END $$;

ROLLBACK;
