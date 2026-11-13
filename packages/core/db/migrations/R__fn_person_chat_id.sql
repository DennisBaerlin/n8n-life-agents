-- ============================================================
-- fn_person_chat_id (READ-ONLY, Identity-Helper — die Umkehrung von fn_resolve_sender)
--   Liefert die Telegram-chat_id (= telegram_user_id) einer Person aus dem family-Facts-Sidecar
--   (persons[] WHERE person_id = <slug>). Schwester von agent.fn_resolve_sender (telegram_user_id -> person)
--   und agent.fn_owner_person_id (role='owner' -> person), dieselbe Quelle (family-Facts), nur die andere Richtung.
--   Eingabe: p_person_id text (Slug).
--   Rueckgabe: bigint, NULL bei ungepairter oder unbekannter Person (der Caller skippt den Send graceful).
--   Zweck: per-Person-Crons und -Alerts senden an die eigene chat_id der Person statt an die Owner-chat_id.
--
--   Telegram-Invariante: im 1:1-Privat-Chat gilt chat.id == from.id (Telegram-Bot-API-Garantie), und der Bot ist
--   private-only ("Allowed Chat IDs = eigene User-ID") -> die telegram_user_id ist die private chat_id. Quelle ist
--   bewusst nicht agent.pairing_state.chat_id (nullable, nicht person-eindeutig, ephemerer Bootstrap-Zustand).
--
--   Deterministisch, RAISE-frei: person_id ist PK in agent.persons -> hoechstens eine family-Person je Slug;
--   LIMIT 1 (Paritaet fn_owner_person_id). Der jsonb_typeof='number'-Guard filtert Personen ohne telegram_user_id
--   -> kein Cast auf null/Junk.
--
--   search_path nicht gepinnt, kein REVOKE-Tail (Paritaet fn_resolve_sender/fn_owner_person_id: Identity-Helper,
--   kein DEFINER-Fenster; alle Refs schema-qualifiziert).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_person_chat_id(p_person_id text)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT (pp->>'telegram_user_id')::bigint
    FROM agent.core_contexts c,
         jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family'
      AND pp->>'person_id' = p_person_id
      AND jsonb_typeof(pp->'telegram_user_id') = 'number'
    LIMIT 1;
$$;

-- ============================================================
-- core.fn_person_chat_id (publiziertes SECURITY-DEFINER-Fenster auf das agent-Primitiv oben)
--   Eingabe: p_person_id text. Rueckgabe: telegram_user_id (= private chat_id) der Person oder NULL
--   (ungepairt/unbekannt). Reiner Delegat, die Logik lebt im agent-Primitiv.
--   Warum: fn_create_case (estate) laeuft unter der engen Rolle estate_rw und muss den Guard
--   "subject == Sender selbst" (kein Fall ueber sich selbst) durchsetzen, also die chat_id des Subjekts mit
--   der Sender-chat_id vergleichen. agent.fn_person_chat_id liest Schema agent (family-Facts), das estate_rw
--   nicht sieht ('permission denied for schema agent') -> publiziertes DEFINER-Fenster in core
--   (Cross-Schema-Read-Regel .claude/rules/sql.md).
--   Generisch (kein Paket-Literal): EXECUTE grantet core.fn_provision_package_roles an jede <pkg>_rw
--   (nur _rw: reiner Write-Pfad-Guard, Muster core.fn_check_write_permission).
--   Beide fns stehen bewusst in dieser Datei (Ausnahme von "eine Repeatable pro Function": Primitiv und
--   Fenster aendern sich nur zusammen, wie bei fn_check_write_permission).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_person_chat_id(p_person_id text)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
    SELECT agent.fn_person_chat_id(p_person_id);
$$;

REVOKE ALL ON FUNCTION core.fn_person_chat_id(text) FROM public;
