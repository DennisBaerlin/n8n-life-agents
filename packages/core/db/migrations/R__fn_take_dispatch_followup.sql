-- ============================================================
-- agent.fn_take_dispatch_followup(p) — Folge-Bindung einmalig lesen UND loeschen (2026-10-28)
--   Gelesen im Agenten-Pfad des Orchestrators (NACH dem Command-Router: ein /help verbraucht sie nicht) fuer genau die
--   naechste Text-Nachricht nach einem Knopf-Lauf. Gueltig 30 Minuten ab dem Setzen (TTL beim Lesen; eine abgelaufene
--   Zeile wird ebenfalls geloescht). Einmalig, weil ab dem ersten gerouteten Folge-Turn das Router-Gedaechtnis den Faden
--   traegt (Sticky-Regel) — bei uns anders als ein Dauer-Zustand bis zum Handoff (arch-challenge 2026-10-28).
--   p: { chat_id }   RUECKGABE: text 'agent.<name>' | NULL. Nie RAISE.
--   Tests: tests/db/core/test_fn_dispatch_followup.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_take_dispatch_followup(p jsonb)
RETURNS text
LANGUAGE sql
SET search_path = pg_catalog, pg_temp
AS $$
    WITH d AS (
        DELETE FROM agent.dispatch_followup f
        WHERE f.chat_id = COALESCE(p->>'chat_id', '')
        RETURNING f.agent, f.set_at
    )
    SELECT d.agent FROM d WHERE d.set_at > now() - interval '30 minutes';
$$;
