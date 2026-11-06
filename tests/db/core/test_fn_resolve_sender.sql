-- tests/db/core/test_fn_resolve_sender.sql
-- Deterministische Sender-Aufloesung des Orchestrator-Pre-Routers (Phase 4 Multi-User-Wiring):
--   fn_resolve_sender(from.id) ist der read-only Schritt VOR dem LLM, der eine numerische
--   Telegram-Identitaet auf ein Haushaltsmitglied abbildet (sender_member-Injektion) bzw.
--   bei Unbekannten den Pairing-/Owner-Notify-Pfad ausloest.
--   * unbekannte ID            -> {found:false}            (Knock-/Owner-Notify-Pfad)
--   * bekannte (gepairte) ID   -> {found:true, person_id, full_name, role, language}
--   * NULL-telegram_user_id einer Person matcht NIE (Skelett vor dem Pairing bleibt "unbekannt")
-- Fixture: family mit owner (gepairt, tg=111, language=de) + child-Skelett (ohne telegram_user_id),
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'resolve_sender test fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','render_fn','fn_household_context',
            'facts', jsonb_build_object(
              'persons', jsonb_build_array(
                jsonb_build_object('person_id','powner','first_name','Owner','last_name','Person',
                                   'role','owner','birth_date','1980-01-01','language','de',
                                   'telegram_user_id', 111, 'as_of','2026-06-11'),
                jsonb_build_object('person_id','pchild','first_name','Kid','last_name','Person',
                                   'role','child','birth_date','2012-03-03','as_of','2026-06-11')
              ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  -- ---------- unbekannte ID -> {found:false} (loest den Owner-Notify-Pfad aus) ----------
  r := agent.fn_resolve_sender(999999);
  IF (r->>'found')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL resolve_sender [unbekannte ID nicht als found:false: %]', r; END IF;

  -- ---------- bekannte gepairte ID -> volle Identitaet ----------
  r := agent.fn_resolve_sender(111);
  IF (r->>'found')::boolean IS DISTINCT FROM true
     OR r->>'person_id' IS DISTINCT FROM 'powner'
     OR r->>'role'      IS DISTINCT FROM 'owner'
     OR r->>'full_name' IS DISTINCT FROM 'Owner Person'
     OR r->>'language'  IS DISTINCT FROM 'de'
     OR (r->>'chat_id')::bigint IS DISTINCT FROM 111 THEN   -- WP-5c: kanonische chat_id = telegram_user_id
    RAISE EXCEPTION 'FAIL resolve_sender [gepairte ID falsch aufgeloest: %]', r; END IF;

  -- ---------- Skelett ohne telegram_user_id bleibt "unbekannt" (kein NULL-Match) ----------
  -- pchild traegt KEINE telegram_user_id -> eine Anfrage einer beliebigen fremden ID darf ihn nie
  -- treffen (der NULL-Guard in fn_resolve_sender). Wir pruefen das ueber eine ID, die niemand traegt.
  r := agent.fn_resolve_sender(0);
  IF (r->>'found')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL resolve_sender [ID 0 matcht ein unverknuepftes Skelett: %]', r; END IF;

  RAISE NOTICE 'PASS fn_resolve_sender [unbekannt->false, gepairt->Identitaet, Skelett-NULL kein Match]';
END $$;

ROLLBACK;
