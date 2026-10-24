-- tests/db/estate/test_fn_public_holidays.sql
-- WS-3 Fristen-Engine: Gauss-Osterformel + bundesweite/landesspezifische Feiertage. Self-contained.
BEGIN;

DO $$
DECLARE
  v_by DATE[] := estate.fn_public_holidays(2024, 'bayern');
  v_be DATE[] := estate.fn_public_holidays(2024, 'berlin');
  v_sn DATE[] := estate.fn_public_holidays(2024, 'sachsen');
BEGIN
  -- Osterberechnung (Ostersonntag SELBST ist kein Feiertag; Karfreitag=Ostern-2, Ostermontag=Ostern+1).
  IF make_date(2024,3,31) = ANY(v_by) THEN RAISE EXCEPTION 'FAIL [Ostersonntag ist kein Feiertag]'; END IF;
  IF NOT (make_date(2024,3,29) = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Karfreitag 2024=29.03. fehlt]'; END IF;
  IF NOT (make_date(2024,4,1)  = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Ostermontag 2024=01.04. fehlt]'; END IF;
  IF NOT (make_date(2024,5,9)  = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Himmelfahrt 2024=09.05. fehlt]'; END IF;
  IF NOT (make_date(2024,5,20) = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Pfingstmontag 2024=20.05. fehlt]'; END IF;
  -- 2025 Ostersonntag = 20.04. -> Karfreitag 18.04.
  IF NOT (make_date(2025,4,18) = ANY(estate.fn_public_holidays(2025,'bayern'))) THEN RAISE EXCEPTION 'FAIL [Karfreitag 2025=18.04. fehlt]'; END IF;
  RAISE NOTICE 'PASS [Osterformel + bewegliche Feiertage]';

  -- Bundesweite Feiertage (in jedem Bundesland).
  IF NOT (make_date(2024,1,1)  = ANY(v_be)) THEN RAISE EXCEPTION 'FAIL [Neujahr fehlt BE]'; END IF;
  IF NOT (make_date(2024,10,3) = ANY(v_be)) THEN RAISE EXCEPTION 'FAIL [Einheit fehlt BE]'; END IF;
  IF NOT (make_date(2024,12,26)= ANY(v_be)) THEN RAISE EXCEPTION 'FAIL [2. Weihnachtstag fehlt BE]'; END IF;
  RAISE NOTICE 'PASS [bundesweite Feiertage]';

  -- Landesspezifisch: Allerheiligen (BY ja / BE nein), Fronleichnam (BY ja), Reformationstag (SN ja / BY nein),
  -- Heilige Drei Koenige (BY ja / BE nein), Buss- und Bettag (SN, Mittwoch vor 23.11. -> 2024=20.11.).
  IF NOT (make_date(2024,11,1) = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Allerheiligen fehlt BY]'; END IF;
  IF     (make_date(2024,11,1) = ANY(v_be)) THEN RAISE EXCEPTION 'FAIL [Allerheiligen faelschlich in BE]'; END IF;
  IF NOT (make_date(2024,5,30) = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Fronleichnam 2024=30.05. fehlt BY]'; END IF;
  IF NOT (make_date(2024,1,6)  = ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Hl. Drei Koenige fehlt BY]'; END IF;
  IF     (make_date(2024,1,6)  = ANY(v_be)) THEN RAISE EXCEPTION 'FAIL [Hl. Drei Koenige faelschlich BE]'; END IF;
  IF NOT (make_date(2024,10,31)= ANY(v_sn)) THEN RAISE EXCEPTION 'FAIL [Reformationstag fehlt SN]'; END IF;
  IF     (make_date(2024,10,31)= ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Reformationstag faelschlich BY]'; END IF;
  IF NOT (make_date(2024,11,20)= ANY(v_sn)) THEN RAISE EXCEPTION 'FAIL [Buss- und Bettag 2024=20.11. fehlt SN]'; END IF;
  IF     (make_date(2024,11,20)= ANY(v_by)) THEN RAISE EXCEPTION 'FAIL [Buss- und Bettag faelschlich BY]'; END IF;
  RAISE NOTICE 'PASS [landesspezifische Feiertage]';

  -- Unbekannter/leerer Slug -> nur bundesweite (kein Wurf, Frauentag NICHT dabei).
  IF (make_date(2024,3,8) = ANY(estate.fn_public_holidays(2024,'gibtsnicht'))) THEN
    RAISE EXCEPTION 'FAIL [unbekannter Slug bekommt Landesfeiertag]';
  END IF;
  IF NOT (make_date(2024,1,1) = ANY(estate.fn_public_holidays(2024,''))) THEN
    RAISE EXCEPTION 'FAIL [leerer Slug -> bundesweite fehlen]';
  END IF;
  RAISE NOTICE 'PASS [unbekannter/leerer Bundesland-Slug graceful]';
END $$;

ROLLBACK;
