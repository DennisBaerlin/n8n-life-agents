-- ============================================================
-- core:V019 — Fakten-Konsolidierung (Phase A): EIN Schreibweg + Core→finance-Fakten-Naehte
--   Einmalige, nicht-idempotente Deltas (Flyway-versioned; self-contained, ruft keine R__-fns):
--   (0) Vorab-Check der neuen reservierten Core-Form-Keys (persons/household) gegen den Bestand — eine
--       verletzende Zeile liesse sich nach dem Update nicht mehr aendern (der facts-Trigger feuert bei JEDEM
--       UPDATE einer facts-tragenden Zeile) -> laut beim Update abbrechen statt spaeter still blockieren.
--   (1) DROP der abgeloesten fns: fn_set_household_facts + fn_set_profile_facts (-> agent.fn_set_context_facts)
--       und agent.fn_finance_profile_context (Renderer zieht als finance.fn_render_finance_profile ins Paket).
--   (2) Stale Core-Registry-Zeile des Finanzprofil-Renderers loeschen (der finance-Seed setzt die neue; auf einer
--       Core-only-Instanz bliebe sonst eine Zeile auf eine gedroppte fn).
--   (3) Aktualitaets-Waechter household_facts_freshness auf die R__-fn core.fn_stale_facts_count() umstellen —
--       NUR wenn die gespeicherte Abfrage byte-gleich einer je ausgelieferten Fassung ist (der Owner kann die
--       Spec per fn_set_monitor_trigger editieren -> eine geaenderte bleibt unberuehrt; frische DB: No-op, der
--       Init-Seed traegt schon die neue Spec). Die alte Fassung ist die einzige, die je ausgeliefert wurde
--       (git log ueber agent.monitor_init.sql).
-- ============================================================

-- (0) Vorab-Check
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(c.name, ', ') INTO v_bad
    FROM agent.core_contexts c
    WHERE c.metadata ? 'facts'
      AND (   (c.metadata->'facts' ? 'household' AND jsonb_typeof(c.metadata->'facts'->'household') IS DISTINCT FROM 'object')
           OR (c.metadata->'facts' ? 'persons'   AND jsonb_typeof(c.metadata->'facts'->'persons')   IS DISTINCT FROM 'array')
           OR (jsonb_typeof(c.metadata->'facts'->'persons') = 'array' AND EXISTS (
                   SELECT 1 FROM jsonb_array_elements(c.metadata->'facts'->'persons') e
                   WHERE jsonb_typeof(e) IS DISTINCT FROM 'object' OR COALESCE(e->>'person_id', '') !~ '^[a-z0-9_]+$')));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'core:V019: facts-Sidecar(s) verletzen die reservierten Core-Form-Keys persons/household: % — bitte vor dem Update bereinigen', v_bad;
    END IF;
END $$;

-- (1) abgeloeste fns
DROP FUNCTION IF EXISTS agent.fn_set_household_facts(jsonb);
DROP FUNCTION IF EXISTS agent.fn_set_profile_facts(jsonb);
DROP FUNCTION IF EXISTS agent.fn_finance_profile_context(text);

-- (2) stale Core-Renderer-Zeile
DELETE FROM core.context_renderers
WHERE context_name = 'finance_profile' AND render_fn = 'agent.fn_finance_profile_context';

-- (3) Waechter-Spec (geguardet auf die ausgelieferte Fassung)
UPDATE agent.monitor_triggers
SET acquisition_spec = jsonb_build_object('query', 'SELECT core.fn_stale_facts_count()')
WHERE origin = 'core'
  AND label = 'household_facts_freshness'
  AND acquisition_spec IN (
      jsonb_build_object('query',
          'SELECT COUNT(*) FROM (SELECT (p_->>''as_of'')::date AS d FROM agent.core_contexts c_, jsonb_array_elements(COALESCE(c_.metadata->''facts''->''persons'', ''[]''::jsonb)) p_ WHERE c_.name IN (''family'', ''finance_profile'')) s WHERE s.d IS NULL OR s.d < CURRENT_DATE - INTERVAL ''12 months''')
  );
