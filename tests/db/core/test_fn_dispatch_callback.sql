-- tests/db/core/test_fn_dispatch_callback.sql
-- Phase 0 WS-0c CB + Member-Permeabilitaet: core.fn_dispatch_callback — generischer Callback-Prefix-Dispatcher
-- mit fail-closed MEMBER-GATE. Schlaegt das callback_data-Prefix (vor dem ersten ":") in core.callback_handlers
-- nach, RE-RESOLVT den Sender selbst (Zero-Trust) und laesst VOR dem EXECUTE nur durch: Owner immer, aufgeloestes
-- Mitglied nur bei member_permeable, sonst {ok:false}. Self-contained: family-Kontext (Owner/Partner/Kind mit
-- telegram_user_id) + Fake-Handler + Registry-Zeilen, alles in BEGIN..ROLLBACK.
BEGIN;

-- Fake-Handler (Echo): gibt {ok:true, toast:'echo', got} zurueck -> "wurde EXECUTEt?" ist am Ergebnis sichtbar.
CREATE OR REPLACE FUNCTION core.fn_test_cb_echo(p jsonb)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('ok', true, 'toast', 'echo', 'got', p->>'data');
$f$;

-- Registry: ein member_permeable=true-Prefix + ein owner-only-Prefix (false, macht den Deny-Zweig erreichbar —
-- beide PROD-Prefixe job/est sind permeable) + eine Zeile mit fehlender Handler-fn.
INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable) VALUES
  ('tcb',    'core.fn_test_cb_echo',    'core', TRUE),
  ('tcbown', 'core.fn_test_cb_echo',    'core', FALSE),
  ('gone',   'core.fn_no_such_handler', 'core', TRUE);

-- family-Kontext: Owner(111) + Partner(222) + Kind(333) mit telegram_user_id -> fn_resolve_sender loest auf.
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'dispatch-cb test fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','owner','first_name','Erika','last_name','Muster',
                             'role','owner','birth_date','1980-01-01','telegram_user_id',111,'language','de','as_of','2026-06-11'),
          jsonb_build_object('person_id','partner','first_name','Hans','last_name','Muster',
                             'role','partner','birth_date','1982-01-01','telegram_user_id',222,'language','ko','as_of','2026-06-11'),
          jsonb_build_object('person_id','kid','first_name','Kim','last_name','Muster',
                             'role','child','birth_date','2015-01-01','telegram_user_id',333,'as_of','2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

-- Katalog-Fixture: Text = Sprach-Marker + Key (Toasts des Gates in der Sprache des Tippenden, Textkatalog §3.11).
INSERT INTO core.ui_texts (key, lang, text, package)
SELECT k, l, upper(l) || ':' || k, 'core'
FROM unnest(ARRAY['core.toast.unresolved_sender','core.toast.owner_only']) k
CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;

DO $$
DECLARE r jsonb;
BEGIN
  -- TEST 1: Owner + member_permeable-Prefix -> EXECUTE + Passthrough
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcb:up:12345','chat_id',111,'callback_id','c1'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'echo' THEN RAISE EXCEPTION 'FAIL [1] Owner+permeable nicht EXECUTEt: %', r; END IF;
  IF r->>'got' IS DISTINCT FROM 'tcb:up:12345' THEN RAISE EXCEPTION 'FAIL [1] Payload nicht durchgereicht: %', r; END IF;
  RAISE NOTICE 'PASS [1] Owner + permeable -> EXECUTE + Passthrough';

  -- TEST 2: Owner + owner-only-Prefix (member_permeable=false) -> EXECUTE (Owner passiert IMMER)
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcbown:x','chat_id',111));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'echo' THEN RAISE EXCEPTION 'FAIL [2] Owner+owner-only nicht EXECUTEt: %', r; END IF;
  RAISE NOTICE 'PASS [2] Owner + owner-only -> EXECUTE';

  -- TEST 3: Partner (Nicht-Owner) + member_permeable=true -> EXECUTE
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcb:up:1','chat_id',222));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'echo' THEN RAISE EXCEPTION 'FAIL [3] Partner+permeable nicht EXECUTEt: %', r; END IF;
  RAISE NOTICE 'PASS [3] Partner + permeable -> EXECUTE';

  -- TEST 4: Partner + member_permeable=false -> owner_only_callback, KEIN EXECUTE
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcbown:x','chat_id',222));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'owner_only_callback' THEN RAISE EXCEPTION 'FAIL [4] Partner+owner-only nicht geblockt: %', r; END IF;
  IF (r->>'got') IS NOT NULL OR r->>'toast' = 'echo' THEN RAISE EXCEPTION 'FAIL [4] Handler lief trotz owner_only_callback: %', r; END IF;
  IF r->>'toast' IS DISTINCT FROM 'KO:core.toast.owner_only' THEN RAISE EXCEPTION 'FAIL [4] Toast in der Sprache des Tippenden (ko): %', r; END IF;
  RAISE NOTICE 'PASS [4] Partner + owner-only -> owner_only_callback, KEIN EXECUTE';

  -- TEST 5: Kind (Mitglied) + member_permeable=true -> EXECUTE (Dispatcher-Grob-Gate laesst durch; feine
  -- adults_only-Auth ist Sache des HANDLERs, hier bewusst der Echo ohne adults_only -> laeuft)
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcb:up:1','chat_id',333));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'toast' IS DISTINCT FROM 'echo' THEN RAISE EXCEPTION 'FAIL [5] Kind+permeable nicht EXECUTEt (Grob-Gate): %', r; END IF;
  RAISE NOTICE 'PASS [5] Kind + permeable -> EXECUTE (feine adults_only-Auth ist Handler-Sache)';

  -- TEST 6: unaufgeloester Sender (999 nicht in family) + permeable -> unresolved_sender, KEIN EXECUTE
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcb:up:1','chat_id',999));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unresolved_sender' THEN RAISE EXCEPTION 'FAIL [6] unaufgeloester Sender nicht geblockt: %', r; END IF;
  IF r->>'toast' = 'echo' THEN RAISE EXCEPTION 'FAIL [6] Handler lief trotz unresolved_sender: %', r; END IF;
  IF r->>'toast' IS DISTINCT FROM 'DE:core.toast.unresolved_sender' THEN RAISE EXCEPTION 'FAIL [6] unaufgeloest -> Toast in Owner-Sprache (de): %', r; END IF;
  RAISE NOTICE 'PASS [6] unaufgeloester Sender -> unresolved_sender, KEIN EXECUTE';

  -- TEST 7: leere / nicht-numerische chat_id -> RAISE-frei -> found:false -> unresolved_sender (KEIN Crash)
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcb:up:1','chat_id',''));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unresolved_sender' THEN RAISE EXCEPTION 'FAIL [7a] leere chat_id nicht RAISE-frei geblockt: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data','tcb:up:1','chat_id','abc'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unresolved_sender' THEN RAISE EXCEPTION 'FAIL [7b] nicht-numerische chat_id nicht RAISE-frei geblockt: %', r; END IF;
  RAISE NOTICE 'PASS [7] leere/nicht-numerische chat_id -> RAISE-frei -> unresolved_sender';

  -- TEST 8: unbekannter Prefix (keine Registry-Zeile) -> unknown_callback_prefix (vor dem Sender-Gate)
  r := core.fn_dispatch_callback(jsonb_build_object('data','unbekannt:x','chat_id',111));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'unknown_callback_prefix' THEN RAISE EXCEPTION 'FAIL [8] unbekannter Prefix nicht abgewiesen: %', r; END IF;
  IF r->>'prefix' IS DISTINCT FROM 'unbekannt' THEN RAISE EXCEPTION 'FAIL [8] prefix-Echo falsch: %', r; END IF;
  RAISE NOTICE 'PASS [8] unbekannter Prefix -> unknown_callback_prefix';

  -- TEST 9: registrierter Prefix, Handler-fn fehlt (Owner passiert das Gate) -> handler_fn_missing
  r := core.fn_dispatch_callback(jsonb_build_object('data','gone:x','chat_id',111));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS DISTINCT FROM 'handler_fn_missing' THEN RAISE EXCEPTION 'FAIL [9] fehlende Handler-fn nicht erkannt: %', r; END IF;
  RAISE NOTICE 'PASS [9] fehlende Handler-fn -> handler_fn_missing';

  -- TEST 10: leeres/fehlendes data -> empty (vor allem anderen, kein Crash)
  r := core.fn_dispatch_callback(jsonb_build_object('chat_id',111));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%empty%' THEN RAISE EXCEPTION 'FAIL [10] leeres data nicht abgewiesen: %', r; END IF;
  RAISE NOTICE 'PASS [10] leeres data -> ok:false empty';
END $$;

ROLLBACK;
