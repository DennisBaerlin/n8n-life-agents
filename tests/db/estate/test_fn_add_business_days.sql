-- tests/db/estate/test_fn_add_business_days.sql
-- WS-3 Fristen-Engine: § 28 PStG-Werktage (Sa/So/Feiertage zaehlen nicht). Self-contained.
BEGIN;

DO $$
BEGIN
  -- Normalfall: Montag 03.06.2024 + 3 Werktage = Donnerstag 06.06.2024 (kein Wochenende/Feiertag dazwischen).
  IF estate.fn_add_business_days('2024-06-03'::date, 3, 'berlin') <> '2024-06-06'::date THEN
    RAISE EXCEPTION 'FAIL [Mo +3 WT: % statt 2024-06-06]', estate.fn_add_business_days('2024-06-03'::date, 3, 'berlin');
  END IF;

  -- Wochenend-Ueberlauf: Donnerstag 06.06.2024 + 3 WT -> Fr(1), Mo(2), Di(3) = Dienstag 11.06.2024.
  IF estate.fn_add_business_days('2024-06-06'::date, 3, 'berlin') <> '2024-06-11'::date THEN
    RAISE EXCEPTION 'FAIL [Do +3 WT ueber WE: % statt 2024-06-11]', estate.fn_add_business_days('2024-06-06'::date, 3, 'berlin');
  END IF;

  -- § 28 PStG ueber Ostern: Todestag Do 28.03.2024 + 3 Werktage. Fr 29.03=Karfreitag (Feiertag),
  -- Sa/So raus, Mo 01.04=Ostermontag (Feiertag) -> Di 02.04(1), Mi 03.04(2), Do 04.04(3) = 04.04.2024.
  IF estate.fn_add_business_days('2024-03-28'::date, 3, 'bayern') <> '2024-04-04'::date THEN
    RAISE EXCEPTION 'FAIL [PStG ueber Ostern: % statt 2024-04-04]', estate.fn_add_business_days('2024-03-28'::date, 3, 'bayern');
  END IF;

  -- Landesabhaengigkeit: Reformationstag Do 31.10.2024 zaehlt in SN nicht als Werktag, in BY schon.
  -- Start Mi 30.10.2024 + 1 WT: SN -> Do 31.10 ist Feiertag -> Fr 01.11 (in SN kein Allerheiligen) = 01.11;
  --                             BY -> Do 31.10 ist Werktag = 31.10.
  IF estate.fn_add_business_days('2024-10-30'::date, 1, 'sachsen') <> '2024-11-01'::date THEN
    RAISE EXCEPTION 'FAIL [SN Reformationstag ueberspringen: %]', estate.fn_add_business_days('2024-10-30'::date, 1, 'sachsen');
  END IF;
  IF estate.fn_add_business_days('2024-10-30'::date, 1, 'bayern') <> '2024-10-31'::date THEN
    RAISE EXCEPTION 'FAIL [BY Reformationstag ist Werktag: %]', estate.fn_add_business_days('2024-10-30'::date, 1, 'bayern');
  END IF;

  -- Grenzen: 0/NULL -> unveraendert.
  IF estate.fn_add_business_days('2024-06-03'::date, 0, 'berlin') <> '2024-06-03'::date THEN
    RAISE EXCEPTION 'FAIL [0 WT nicht identisch]'; END IF;
  IF estate.fn_add_business_days('2024-06-03'::date, NULL, 'berlin') <> '2024-06-03'::date THEN
    RAISE EXCEPTION 'FAIL [NULL WT nicht identisch]'; END IF;

  RAISE NOTICE 'PASS [fn_add_business_days: Normal/WE/Ostern/Landesfeiertag/Grenzen]';
END $$;

ROLLBACK;
