-- ============================================================
-- core.fn_advisor_pins(p) — offener Berater-Entwurf einer Person als Router-Flags (READ)
--   Die eine Adresse fuer "wer hat einen offenen Entwurf": der Orchestrator-Knoten 'Interview pin' liest beide Flags
--   in den Laufzeit-Block des Router-Prompts (Regel 3 bzw. 3c in orchestrator_agent_instructions.md).
--   Massgeblich ist der juengste Entwurf (status draft) der Person, dessen Paket aktiv ist (Join core.advisors +
--   core.package_registry):
--     interview_advisor = sein advisor_agent, wenn er juenger als 2 Stunden ist (Gespraech laeuft, kurze Antworten
--                         gehoeren dem Berater);
--     paused_advisor    = sein advisor_agent, wenn er 2 Stunden oder aelter und juenger als
--                         advisor.rollout_draft_stale_days (Default 30) ist (eine ausdrueckliche Bitte "weiter mit der
--                         Beratung" erreicht den Berater). Ein heisser Entwurf laesst paused_advisor leer.
--   Personen-Regel wie der Interview-Pin: eigener Entwurf (person_id = p.person_id); Haushalts-Entwurf (person_id NULL)
--   nur fuer role owner. Nie der Entwurf eines anderen Mitglieds.
--   Eingabe p: { person_id, role } aus agent.fn_resolve_sender (nie LLM).
--   Rueckgabe jsonb genau { interview_advisor: text|null, paused_advisor: text|null }; wirft nie (Fehler -> beide null).
--   STABLE, INVOKER, nur Host-Cred (wie der heutige Knoten): person_id und role kommen vom Aufrufer, ein core_ro-Grant
--   liesse jede freie core_ro-Abfrage (guide/monitor postgres_select) fremde Entwuerfe erfragen. search_path gepinnt.
--   Tests: tests/db/core/test_fn_advisor_pins.sql, tests/db/cross/test_role_permissions.sql (core_ro abgewiesen)
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_pins(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid   text := NULLIF(p->>'person_id', '');
    v_owner boolean := COALESCE(p->>'role', '') = 'owner';
    v_stale int;
    v_agent text;
    v_at    timestamptz;
BEGIN
    v_stale := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'rollout_draft_stale_days'), '')::int, 30);
    SELECT a.advisor_agent, ap.updated_at INTO v_agent, v_at
      FROM agent.advisor_plans ap
      JOIN core.advisors a ON a.domain = ap.domain
      JOIN core.package_registry pr ON pr.package = a.package AND pr.status = 'active'
     WHERE ap.status = 'draft'
       AND ((ap.person_id IS NULL AND v_owner) OR (v_pid IS NOT NULL AND ap.person_id = v_pid))
     ORDER BY ap.updated_at DESC
     LIMIT 1;
    RETURN jsonb_build_object(
        'interview_advisor', CASE WHEN v_at > now() - interval '2 hours' THEN v_agent END,
        'paused_advisor',    CASE WHEN v_at <= now() - interval '2 hours' AND v_at > now() - make_interval(days => v_stale)
                                  THEN v_agent END);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('interview_advisor', NULL, 'paused_advisor', NULL);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_pins(jsonb) FROM public;
