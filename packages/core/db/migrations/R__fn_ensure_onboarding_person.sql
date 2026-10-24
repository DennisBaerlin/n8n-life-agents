-- ============================================================
-- core.fn_ensure_onboarding_person (P2b-1) — Lazy-Materialisierung der per_user-Onboarding-Zeilen einer Person
--   p_package, p_pid: materialisiert je section_key EINE 'unknown'-Zeile fuer (p_pid) aus dem (Owner-geseedeten)
--   Sektions-Katalog von <pkg>.onboarding_state, falls noch keine (section_key, person_id)-Zeile existiert.
--
--   WARUM: career.onboarding_state ist pro Person (P2b-1). Der Host-Seeder _seed_onboarding_sections seedet nur
--   die OWNER-Zeilen (zur Seed-Zeit existiert nur der Owner); die Zeilen jeder weiteren Person entstehen LAZY beim
--   ersten Schreibzugriff (der Nutzer markiert eine Sektion). Diese fn ist der EINE Ort dieser Materialisierung
--   (nur core.fn_set_onboarding_section ruft sie, VOR dem UPDATE) — die Lese-fns (fn_onboarding_status/_overview)
--   materialisieren NICHT (sie sind STABLE und rechnen die Vollstaendigkeit KATALOG-basiert: fehlende Zeile =
--   'unknown' = nicht complete -> kein vacuous-true, Gate bleibt fuer eine nie-onboardete Person zu).
--
--   D10 / Auth: SECURITY INVOKER (Parität core.fn_set_onboarding_section) — der INSERT kreuzt keine Schema-Grenze,
--   die der Aufrufer nicht ohnehin darf: fn_set laeuft fuer career unter der Haupt-RW-Cred (schreibt career.* und
--   liest agent.*); fuer household-Pakete (finance/guide) wird diese fn NIE gerufen (kein person-Scope). search_path
--   gepinnt; Suffix '.onboarding_state' ist LITERAL (nie 2. %I) + Name-Regex + to_regclass-Guard. p_package ist
--   build-time-konstant (nie $fromAI). p_pid kommt deterministisch aus fn_resolve_sender (FK -> agent.persons
--   sichert, dass nur eine reale Person materialisiert wird).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ensure_onboarding_person(p_package text, p_pid text)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_rel text;
BEGIN
    -- Nur per_user-Pakete (career) materialisieren; core (Host-Sonderfall) + unbekannt/leer -> No-Op.
    IF p_pid IS NULL OR p_package IS NULL OR p_package = 'core' OR p_package !~ '^[a-z][a-z0-9_]*$' THEN
        RETURN;
    END IF;
    v_rel := to_regclass(format('%I.onboarding_state', p_package))::text;   -- Suffix LITERAL, nie 2. %I
    IF v_rel IS NULL THEN RETURN; END IF;

    -- Je section_key EINE Zeile fuer p_pid aus dem Katalog (DISTINCT ON: gleiche ord/label je Sektion). INSERT...
    -- SELECT auf derselben Tabelle ist erlaubt (Pre-INSERT-Snapshot); ON CONFLICT (section_key, person_id) DO
    -- NOTHING -> idempotent + greift bestehende Zeilen der Person nicht an. Leerer Katalog -> 0 Zeilen (No-Op).
    EXECUTE format($q$
        INSERT INTO %1$s (section_key, ord, label, person_id)
        SELECT DISTINCT ON (section_key) section_key, ord, label, $1
        FROM %1$s
        ORDER BY section_key, ord
        ON CONFLICT (section_key, person_id) DO NOTHING
    $q$, v_rel) USING p_pid;
END;
$$;
