-- ============================================================
-- core.fn_stale_facts_count() -> integer   (Phase A — Aktualitaets-Waechter household_facts_freshness)
--   Zaehlt die Personen-Fakten (Eintraege in metadata.facts.persons[]) mit as_of aelter als 12 Monate oder
--   ohne as_of, ueber family + die household-Fakten-Kontexte AKTIVER Pakete (EIN Praedikat:
--   core.fn_facts_context_allowed — Fakten inaktiver/deinstallierter Pakete wecken den Owner nicht).
--   Ersetzt die gespeicherte Abfrage mit dem Literal 'finance_profile' (Core kennt kein Paket). Die Core-
--   Trigger-Zeile ruft nur diese fn (agent.monitor_init.sql; Bestand: core:V019) -> der Owner kann die Spec
--   editieren, eine Logik-Aenderung bleibt trotzdem eine reine R__-Aenderung.
--   Ausgefuehrt von fn_monitor_acquire unter SET LOCAL ROLE core_ro -> STABLE INVOKER, search_path gepinnt,
--   array-sicher (jsonb_array_elements nur auf echten Arrays); EXECUTE an core_ro in util_create_core_ro.sql.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_stale_facts_count()
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = pg_catalog, agent, core
AS $$
    SELECT COUNT(*)::integer
    FROM agent.core_contexts c
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(c.metadata->'facts'->'persons') = 'array'
             THEN c.metadata->'facts'->'persons' ELSE '[]'::jsonb END) p
    WHERE core.fn_facts_context_allowed(c.name)
      -- fehlendes as_of zaehlt als veraltet (-infinity); der CASE-Guard verhindert einen Cast-Fehler
      AND COALESCE(CASE WHEN p->>'as_of' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p->>'as_of')::date END,
                   '-infinity'::date) < CURRENT_DATE - INTERVAL '12 months';
$$;
