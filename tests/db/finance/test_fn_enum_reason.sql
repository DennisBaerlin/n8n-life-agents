-- tests/db/finance/test_fn_enum_reason.sql
-- Import-Haertung 2026-10-22: EIN Enum-Guard fuer alle Write-fns (unbekannter Wert -> korrigierbares {ok:false}
-- statt Cast-RAISE + Owner-Alert). (1) leer/NULL -> NULL, (2) gueltiges Label -> NULL, (3) unbekannt -> Grund
-- mit Feldname + Liste der erlaubten Werte (Reihenfolge = Enum-Reihenfolge), (4) kein Trim-Raten (Cast trimmt nicht).
BEGIN;

DO $$
DECLARE
  v_reason TEXT;
BEGIN
  IF finance.fn_enum_reason('finance.property_status'::regtype, NULL, 'status') IS NOT NULL
     OR finance.fn_enum_reason('finance.property_status'::regtype, '', 'status') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1]: leerer Wert muss NULL liefern (Feld nicht genannt)';
  END IF;
  RAISE NOTICE 'PASS [1 leer/NULL -> NULL]';

  IF finance.fn_enum_reason('finance.property_status'::regtype, 'sold', 'status') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2]: gueltiges Label muss NULL liefern';
  END IF;
  RAISE NOTICE 'PASS [2 gueltig -> NULL]';

  v_reason := finance.fn_enum_reason('finance.property_status'::regtype, 'owned', 'status');
  IF v_reason IS NULL OR position('status' IN v_reason) = 0 OR position('owned' IN v_reason) = 0
     OR position('active, sold' IN v_reason) = 0 THEN
    RAISE EXCEPTION 'FAIL [3]: Grund muss Feld, Wert und erlaubte Werte nennen, got %', v_reason;
  END IF;
  RAISE NOTICE 'PASS [3 unbekannt -> Grund mit Werteliste]';

  IF finance.fn_enum_reason('finance.property_status'::regtype, ' sold', 'status') IS NULL THEN
    RAISE EXCEPTION 'FAIL [4]: " sold" ist kein gueltiges Label (der spaetere Cast wuerde scheitern)';
  END IF;
  RAISE NOTICE 'PASS [4 kein Trim-Raten]';
END $$;

ROLLBACK;
