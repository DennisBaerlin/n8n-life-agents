-- tests/db/core/test_fn_handoff_claim_ttl.sql
-- core.fn_handoff_claim_ttl: die eine Lese-Adresse fuer advisor.handoff_claim_ttl_minutes (ohne Zeile -> 120, gesetzt -> Wert).
BEGIN;

DO $$
BEGIN
  DELETE FROM core.config WHERE category = 'advisor' AND key = 'handoff_claim_ttl_minutes';
  IF core.fn_handoff_claim_ttl() IS DISTINCT FROM 120 THEN
    RAISE EXCEPTION 'FAIL [ohne Zeile -> 120]: %', core.fn_handoff_claim_ttl(); END IF;
  PERFORM core.fn_config_seed('{"category":"advisor","key":"handoff_claim_ttl_minutes","value":"45","type":"integer","minimum":"1","package":"core"}');
  IF core.fn_handoff_claim_ttl() IS DISTINCT FROM 45 THEN
    RAISE EXCEPTION 'FAIL [gesetzt -> 45]: %', core.fn_handoff_claim_ttl(); END IF;
  RAISE NOTICE 'PASS fn_handoff_claim_ttl [Rueckfall 120, gesetzter Wert]';
END $$;

ROLLBACK;
