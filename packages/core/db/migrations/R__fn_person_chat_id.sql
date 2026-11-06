-- ============================================================
-- fn_person_chat_id (read-only, Identity-Helper — die Umkehrung von fn_resolve_sender)
--   Liefert die Telegram-chat_id (= telegram_user_id) einer Person aus dem family-Facts-Sidecar
--   (persons[] WHERE person_id = <slug>). Schwester von agent.fn_resolve_sender (telegram_user_id -> person)
--   und agent.fn_owner_person_id (role='owner' -> person) — DIESELBE Single Source of Truth (family-Facts),
--   nur die andere Richtung (DRY / ein Fakt, eine Adresse).
--
--   ZWECK (P2a-Fundament fuer P2b): die per-Person-Cron-Schleife (score_jobs/refresh_market_signals) und die
--   per-Person-Alerts senden Karten/Benachrichtigungen an die EIGENE chat_id der Person statt an die hartkodierte
--   Owner-chat_id. Gebaut + db-getestet in P2a, verdrahtet in P2b (kein Aufrufer in P2a -> verhaltensneutral).
--
--   TELEGRAM-INVARIANTE: im 1:1-Privat-Chat gilt chat.id == from.id (Telegram-Bot-API-Garantie), und der Bot ist
--   private-only ("Allowed Chat IDs = eigene User-ID") -> die telegram_user_id IST die private chat_id. Quelle ist
--   NICHT agent.pairing_state.chat_id (nullable, nicht person-eindeutig, ephemerer Bootstrap-Zustand).
--
--   DETERMINISTISCH + RAISE-FREI: person_id ist PK in agent.persons -> hoechstens eine family-Person je Slug;
--   LIMIT 1 (Paritaet fn_owner_person_id). Der jsonb_typeof='number'-Guard filtert Personen OHNE telegram_user_id
--   (ungepairt) -> kein Cast auf null/Junk -> RUECKGABE NULL (der Caller skippt den Send graceful). Unbekannte
--   person_id -> kein Treffer -> NULL.
--
--   search_path NICHT gepinnt (Paritaet fn_resolve_sender/fn_owner_person_id; alle Refs schema-qualifiziert).
--   KEIN REVOKE-Tail (Paritaet fn_owner_person_id/fn_resolve_sender; Identity-Helper, kein DEFINER-Fenster).
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_person_chat_id.sql
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
--   estate WS-3: fn_create_case laeuft unter der ENGEN Paket-Rolle estate_rw und muss den v1-Guard
--   "subject == Sender selbst" (man legt keinen Fall ueber sich selbst an) durchsetzen — dazu die
--   chat_id des Subjekts mit der Sender-chat_id vergleichen. agent.fn_person_chat_id liest Schema
--   agent (family-Facts), das estate_rw per D10 nicht sieht ('permission denied for schema agent').
--   Cross-Schema-Read-Regel (.claude/rules/sql.md): so eine fn MUSS als publiziertes DEFINER-Fenster
--   nach core. GENERISCH (kein Paket-Literal): EXECUTE grantet core.fn_provision_package_roles an
--   JEDE <pkg>_rw (nur _rw — reiner Write-Pfad-Guard, Muster core.fn_check_write_permission).
--   Reiner Delegat — die Logik lebt ausschliesslich im agent-Primitiv oben (kein Duplikat).
--   BEIDE fns in DIESER Datei (bewusste Ausnahme von "eine Repeatable pro Function": gleicher Name,
--   ein Konzern Primitiv + Fenster, aendern sich nur zusammen — Praezedenz fn_check_write_permission).
--   DEFINER-Hygiene: search_path gepinnt (CVE-2018-1058), Body schema-qualifiziert,
--   REVOKE ALL FROM PUBLIC (Grants zentral in fn_provision_package_roles).
--   RUECKGABE: telegram_user_id (= private chat_id) der Person oder NULL (ungepairt/unbekannt).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_person_chat_id(p_person_id text)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
    SELECT agent.fn_person_chat_id(p_person_id);
$$;

REVOKE ALL ON FUNCTION core.fn_person_chat_id(text) FROM public;
