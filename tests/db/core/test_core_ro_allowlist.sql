-- tests/db/core/test_core_ro_allowlist.sql
-- Nur Freigegebenes lesen: core_ro (Frei-SQL von Guide/Monitor, Monitor-Specs ueber
-- core_ro_eval) liest in agent/core genau die Erlaubnisliste aus util_create_core_ro.sql. Die Soll-Liste steht hier
-- bewusst ein zweites Mal: wer die Liste erweitert, muss den Test mitziehen (Gegenprobe). Eine neue, nicht eingeordnete
-- Tabelle oder View in agent/core macht den Test rot, sobald ein Grant sie fuer core_ro lesbar macht; ebenso ein
-- Default-Privileg, das kuenftige Tabellen still oeffnen wuerde.
BEGIN;

DO $$
DECLARE
  v_allow   text[] := ARRAY[
    'agent.core_contexts', 'agent.guide_onboarding_state', 'agent.monitor_triggers', 'agent.monitor_observations',
    'core.config', 'core.help_catalog', 'core.ui_texts', 'core.ui_languages', 'core.package_registry',
    'core.context_validators', 'core.context_scopes'];
  v_missing text;
  v_leak    text;
  v_dacl    text;
BEGIN
  -- (1) jede Listen-Relation existiert und ist lesbar (fehlt eine, prueft die Liste ins Leere oder der Lesepfad bricht)
  SELECT string_agg(a, ', ') INTO v_missing
    FROM unnest(v_allow) a
   WHERE to_regclass(a) IS NULL OR NOT has_table_privilege('core_ro', a, 'SELECT');
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL allowlist [Listen-Relation fehlt oder nicht lesbar fuer core_ro: %]', v_missing;
  END IF;

  -- (2) alles andere in agent/core (Tabellen, Views, Mat-Views, Partitionen, Fremdtabellen) ist NICHT lesbar
  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY 1) INTO v_leak
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('agent', 'core') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
     AND format('%I.%I', n.nspname, c.relname) <> ALL (v_allow)
     AND has_table_privilege('core_ro', c.oid, 'SELECT');
  IF v_leak IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL allowlist [core_ro liest nicht freigegebene Relation(en): % — Erlaubnisliste in util_create_core_ro.sql pruefen]', v_leak;
  END IF;

  -- (3) kein Default-Privileg fuer core_ro in agent/core (sonst waere jede kuenftige Tabelle still lesbar)
  SELECT string_agg(n.nspname, ', ') INTO v_dacl
    FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace
   WHERE n.nspname IN ('agent', 'core')
     AND EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) x
                  WHERE x.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'core_ro'));
  IF v_dacl IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL allowlist [Default-Privileg fuer core_ro in Schema %]', v_dacl;
  END IF;

  -- (4) kein Schreibrecht irgendeiner Art in agent/core
  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ') INTO v_leak
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('agent', 'core') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
     AND has_table_privilege('core_ro', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
  IF v_leak IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL allowlist [core_ro hat Schreib-/Nebenrechte auf: %]', v_leak;
  END IF;

  RAISE NOTICE 'PASS core_ro_allowlist [% Relationen freigegeben, Rest in agent/core gesperrt, kein Default-Privileg]', cardinality(v_allow);
END $$;

-- (5) Perspektive: unter core_ro wirklich lesbar bzw. gesperrt (has_table_privilege allein sieht RLS-Fehler nicht)
DO $$
DECLARE v_cnt int;
BEGIN
  SET LOCAL ROLE core_ro;
  SELECT count(*) INTO v_cnt FROM agent.guide_onboarding_state;
  BEGIN
    PERFORM 1 FROM agent.guide_learn_candidates LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL allowlist [core_ro liest agent.guide_learn_candidates]';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  RAISE NOTICE 'PASS core_ro_allowlist [Perspektive: Liste lesbar, Lern-Vorschlaege gesperrt]';
END $$;

ROLLBACK;
