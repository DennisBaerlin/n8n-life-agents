-- ============================================================
-- core.fn_app_sees_household(p_person_id text) — die EINE Rollenfrage der Mini-App-Bildschirme (READ)
--   „Sieht diese Person den ganzen Haushalt?“ (docs/package-contract.md §3.12): Allow-List, nur Rolle owner/partner
--   -> true; jede andere, unbekannte oder fehlende Rolle -> false (nie NULL). Jeder Bildschirm-Handler (<pkg>.fn_app_
--   screen_*) fragt hier statt selbst zu entscheiden; was „Eigenes“ je Objekt heisst (Konto-Inhaber, Begünstigte,
--   Kreditnehmer …), bleibt im Handler. Zero-Trust: der Handler ruft das mit der vom Dispatcher aufgeloesten person_id.
--   SECURITY DEFINER (liest agent.persons) + gepinnter search_path + REVOKE PUBLIC; die Handler sind selbst DEFINER und
--   laufen als Eigentuemer, die Host-Rolle hat EXECUTE schemaweit (apply_schema.sh) -> kein Grant an Paket-Rollen.
--   Tests: tests/db/core/test_fn_app_sees_household.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_sees_household(p_person_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, agent, pg_temp
AS $$
    SELECT COALESCE(bool_or(p.role IN ('owner', 'partner')), false)
    FROM agent.persons p
    WHERE p.person_id = p_person_id;
$$;

REVOKE ALL ON FUNCTION core.fn_app_sees_household(text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_app_sees_household(text) FROM context_ro;
    END IF;
END $$;
