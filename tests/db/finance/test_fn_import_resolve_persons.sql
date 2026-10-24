-- tests/db/finance/test_fn_import_resolve_persons.sql
-- Testet fn_import_resolve_persons: je entity_type genau ein Personen-Feld wie im Einzel-Tool, Name -> Slug,
-- leer = Haushalt, alte/fremde Personen-Keys und mehrdeutige Namen -> Fehlertext.
BEGIN;

DO $$
DECLARE
  v JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__irp_a','first_name','Irpa','last_name','Zweifach',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-10-21'),
              jsonb_build_object('person_id','__irp_b','first_name','Irpb','last_name','Zweifach',
                                 'role','partner','birth_date','1981-01-01','as_of','2026-10-21')))))
  ON CONFLICT (name) DO UPDATE
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  -- Name -> *_person_id je Typ
  v := finance.fn_import_resolve_persons('account', '{"name":"X","owner_person":"Irpa Zweifach"}'::jsonb);
  IF v->>'error' IS NOT NULL OR v->'payload'->>'owner_person_id' IS DISTINCT FROM '__irp_a' OR v->'payload' ? 'owner_person' THEN
    RAISE EXCEPTION 'FAIL irp [account]: %', v;
  END IF;
  v := finance.fn_import_resolve_persons('insurance', '{"name":"X","policyholder_person":"Irpb"}'::jsonb);
  IF v->'payload'->>'policyholder_person_id' IS DISTINCT FROM '__irp_b' THEN RAISE EXCEPTION 'FAIL irp [insurance]: %', v; END IF;
  v := finance.fn_import_resolve_persons('loan', '{"name":"X","borrower_person":"Irpa"}'::jsonb);
  IF v->'payload'->>'borrower_person_id' IS DISTINCT FROM '__irp_a' THEN RAISE EXCEPTION 'FAIL irp [loan]: %', v; END IF;
  v := finance.fn_import_resolve_persons('savings_goal', '{"name":"X","beneficiary_person":"Irpb"}'::jsonb);
  IF v->'payload'->>'beneficiary_person_id' IS DISTINCT FROM '__irp_b' THEN RAISE EXCEPTION 'FAIL irp [goal]: %', v; END IF;
  RAISE NOTICE 'PASS fn_import_resolve_persons [Name -> Slug je Typ]';

  -- leer = Haushalt (Feld entfernt, kein Fehler); Typ ohne Person bleibt unveraendert
  v := finance.fn_import_resolve_persons('account', '{"name":"X","owner_person":""}'::jsonb);
  IF v->>'error' IS NOT NULL OR v->'payload' ? 'owner_person' OR v->'payload' ? 'owner_person_id' THEN
    RAISE EXCEPTION 'FAIL irp [leer]: %', v;
  END IF;
  v := finance.fn_import_resolve_persons('recurring_payment', '{"name":"X","amount":5}'::jsonb);
  IF v->>'error' IS NOT NULL OR v->'payload' <> '{"name":"X","amount":5}'::jsonb THEN RAISE EXCEPTION 'FAIL irp [ohne Person]: %', v; END IF;
  RAISE NOTICE 'PASS fn_import_resolve_persons [leer = Haushalt, Typ ohne Person unveraendert]';

  -- Fehler: mehrdeutig, alter Key, *_person_id, fremdes Personen-Feld, Person auf Typ ohne Person
  IF finance.fn_import_resolve_persons('account', '{"owner_person":"Zweifach"}'::jsonb)->>'error' NOT LIKE '%matches 2%' THEN
    RAISE EXCEPTION 'FAIL irp [mehrdeutig]'; END IF;
  IF finance.fn_import_resolve_persons('account', '{"account_holder":"Irpa"}'::jsonb)->>'error' NOT LIKE '%owner_person%' THEN
    RAISE EXCEPTION 'FAIL irp [alter Key]'; END IF;
  IF finance.fn_import_resolve_persons('account', '{"owner_person_id":"__irp_a"}'::jsonb)->>'error' IS NULL THEN
    RAISE EXCEPTION 'FAIL irp [Slug direkt]'; END IF;
  IF finance.fn_import_resolve_persons('account', '{"borrower_person":"Irpa"}'::jsonb)->>'error' IS NULL THEN
    RAISE EXCEPTION 'FAIL irp [fremdes Feld]'; END IF;
  IF finance.fn_import_resolve_persons('stock_buy', '{"owner":"Irpa"}'::jsonb)->>'error' NOT LIKE '%has no person%' THEN
    RAISE EXCEPTION 'FAIL irp [Typ ohne Person]'; END IF;
  -- insurance.beneficiary (Bezugsberechtigter, Freitext) ist KEIN Personen-Key
  IF finance.fn_import_resolve_persons('insurance', '{"beneficiary":"Kinder"}'::jsonb)->>'error' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL irp [beneficiary-Freitext faelschlich abgelehnt]'; END IF;
  RAISE NOTICE 'PASS fn_import_resolve_persons [mehrdeutig / alter Key / Slug / fremdes Feld / Typ ohne Person; beneficiary-Freitext ok]';
END $$;

ROLLBACK;
