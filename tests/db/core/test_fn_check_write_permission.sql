-- tests/db/core/test_fn_check_write_permission.sql
-- P0a: das generische Schreib-Permission-Praedikat agent.fn_check_write_permission(write_permission, chat_id,
-- target_person_id) -> NULL=erlaubt | Grund-Token=abgelehnt (Vertrag wie fn_validate_*). Getestet je STUFE × Rolle,
-- inkl. der Pass-Through-Pfade (nicht-numerisch/leer/NULL chat_id, unresolved) — genau der ::bigint-Numerik-Guard,
-- der sonst ungetestet bliebe (Behavior-Neutralitaets-Kern). Self-contained: family-Fixture (owner 111, partner 222,
-- child 333) in der Transaktion; BEGIN..ROLLBACK.
BEGIN;

-- Inline-Pruefung mit IS DISTINCT FROM (NULL-sicher); ein FAIL -> RAISE EXCEPTION -> ON_ERROR_STOP.
DO $$
DECLARE
  v_r TEXT;
BEGIN
  -- ---------- Fixture: family mit owner/partner/child ----------
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
  RAISE NOTICE 'PASS fixture [family owner/partner/child]';

  -- =========================================================
  -- STUFE owner_only (delegiert an fn_sender_is_member)
  -- =========================================================
  v_r := agent.fn_check_write_permission('owner_only', '111', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [owner_only/owner]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('owner_only', '222', NULL);
  IF v_r IS DISTINCT FROM 'owner_only' THEN RAISE EXCEPTION 'FAIL [owner_only/partner]: erwartet owner_only, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('owner_only', '333', NULL);
  IF v_r IS DISTINCT FROM 'owner_only' THEN RAISE EXCEPTION 'FAIL [owner_only/child]: erwartet owner_only, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('owner_only', 'test_e2e', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [owner_only/non-numeric]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('owner_only', '999', NULL);   -- numerisch, nicht in family
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [owner_only/unresolved]: erwartet NULL, got %', v_r; END IF;
  RAISE NOTICE 'PASS [owner_only: owner->ok, partner/child->reject, non-numeric/unresolved->ok]';

  -- =========================================================
  -- STUFE adults_only (role ∈ owner,partner)
  -- =========================================================
  v_r := agent.fn_check_write_permission('adults_only', '111', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [adults_only/owner]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('adults_only', '222', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [adults_only/partner]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('adults_only', '333', NULL);
  IF v_r IS DISTINCT FROM 'adults_only' THEN RAISE EXCEPTION 'FAIL [adults_only/child]: erwartet adults_only, got %', v_r; END IF;
  -- Numerik-Guard / Pass-Through (m4): nicht-numerisch / leer / NULL / unresolved -> NULL
  v_r := agent.fn_check_write_permission('adults_only', 'test_e2e', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [adults_only/non-numeric]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('adults_only', '', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [adults_only/empty]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('adults_only', NULL, NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [adults_only/null-chat]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('adults_only', '999', NULL);
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [adults_only/unresolved]: erwartet NULL, got %', v_r; END IF;
  RAISE NOTICE 'PASS [adults_only: owner/partner->ok, child->reject, non-numeric/empty/null/unresolved->ok]';

  -- =========================================================
  -- STUFE own_user_only (aufgeloeste Person == Ziel)
  -- =========================================================
  v_r := agent.fn_check_write_permission('own_user_only', '222', 'lena');   -- self
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [own_user_only/self]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('own_user_only', '222', 'erika');  -- fremde Person
  IF v_r IS DISTINCT FROM 'own_user_only' THEN RAISE EXCEPTION 'FAIL [own_user_only/other]: erwartet own_user_only, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('own_user_only', '222', NULL);     -- aufgeloest + Ziel NULL = fail-closed
  IF v_r IS DISTINCT FROM 'own_user_only' THEN RAISE EXCEPTION 'FAIL [own_user_only/null-target]: erwartet own_user_only (fail-closed), got %', v_r; END IF;
  -- m5: nicht-numerische chat_id MIT Ziel -> NULL (fail-OPEN, Sentinel-Paritaet, VOR dem Personen-Vergleich)
  v_r := agent.fn_check_write_permission('own_user_only', 'test_e2e', 'lena');
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [own_user_only/non-numeric]: erwartet NULL (fail-open Sentinel), got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('own_user_only', '999', 'lena');   -- unresolved -> NULL
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [own_user_only/unresolved]: erwartet NULL, got %', v_r; END IF;
  v_r := agent.fn_check_write_permission('own_user_only', NULL, 'lena');    -- NULL chat_id -> fail-open Pass-Through (Numerik-Guard)
  IF v_r IS DISTINCT FROM NULL THEN RAISE EXCEPTION 'FAIL [own_user_only/null-chat]: erwartet NULL, got %', v_r; END IF;
  RAISE NOTICE 'PASS [own_user_only: self->ok, other/null-target->reject, non-numeric/null-chat/unresolved->ok]';

  -- =========================================================
  -- Fremd-Token -> unknown_write_permission (fail-closed; Registry-CHECK verhindert das strukturell)
  -- =========================================================
  v_r := agent.fn_check_write_permission('frobnicate', '111', NULL);
  IF v_r IS DISTINCT FROM 'unknown_write_permission' THEN RAISE EXCEPTION 'FAIL [unknown-token]: erwartet unknown_write_permission, got %', v_r; END IF;
  RAISE NOTICE 'PASS [Fremd-Token -> unknown_write_permission]';
END $$;

ROLLBACK;
