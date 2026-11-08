-- ============================================================
-- test_fn_resolve_contact -- Resolver Name (exakt) + optional Rolle: 0 / 1 / >1 Treffer
--   Gesetz: id nur bei genau einem Treffer (sonst NULL), hit_count immer, candidates nach id sortiert ([] bei 0).
-- ============================================================
BEGIN;
DO $$
DECLARE
    r        RECORD;
    v_notary BIGINT;
    v_lawyer BIGINT;
BEGIN
    INSERT INTO estate.contacts (role, name) VALUES ('notary', 'Notarin Muster') RETURNING id INTO v_notary;
    INSERT INTO estate.contacts (role, name) VALUES ('notary', 'Doppelname Beispiel') RETURNING id INTO v_notary;
    INSERT INTO estate.contacts (role, name) VALUES ('lawyer', 'Doppelname Beispiel') RETURNING id INTO v_lawyer;

    -- 0 Treffer
    SELECT * INTO r FROM estate.fn_resolve_contact('Gibt es nicht');
    IF r.id IS NOT NULL OR r.hit_count <> 0 OR r.candidates <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [0 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [0 Treffer]: id NULL, hit_count 0, candidates []';

    -- genau 1 Treffer
    SELECT * INTO r FROM estate.fn_resolve_contact('Notarin Muster');
    IF r.id IS NULL OR r.hit_count <> 1 OR jsonb_array_length(r.candidates) <> 1
       OR (r.candidates->0->>'name') <> 'Notarin Muster' THEN
        RAISE EXCEPTION 'FAIL [1 Treffer]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    RAISE NOTICE 'PASS [1 Treffer]: id gesetzt';

    -- >1 Treffer: id NULL, beide Kandidaten nach id sortiert
    SELECT * INTO r FROM estate.fn_resolve_contact('Doppelname Beispiel');
    IF r.id IS NOT NULL OR r.hit_count <> 2 OR jsonb_array_length(r.candidates) <> 2
       OR (r.candidates->0->>'id')::bigint <> v_notary OR (r.candidates->1->>'id')::bigint <> v_lawyer THEN
        RAISE EXCEPTION 'FAIL [>1 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [>1 Treffer]: id NULL, hit_count 2, Kandidaten nach id';

    -- Rolle disambiguiert; leere Rolle = kein Filter; falsche Rolle = 0
    SELECT * INTO r FROM estate.fn_resolve_contact('Doppelname Beispiel', 'lawyer');
    IF r.id IS DISTINCT FROM v_lawyer OR r.hit_count <> 1 THEN
        RAISE EXCEPTION 'FAIL [Rolle]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    SELECT * INTO r FROM estate.fn_resolve_contact('Doppelname Beispiel', '');
    IF r.hit_count <> 2 THEN RAISE EXCEPTION 'FAIL [leere Rolle]: hit_count=%', r.hit_count; END IF;
    SELECT * INTO r FROM estate.fn_resolve_contact('Notarin Muster', 'lawyer');
    IF r.hit_count <> 0 OR r.id IS NOT NULL THEN RAISE EXCEPTION 'FAIL [falsche Rolle]: hit_count=%', r.hit_count; END IF;
    RAISE NOTICE 'PASS [Rolle]: filtert, leer = ohne Filter, falsche Rolle = 0';

    -- exakt: Gross-/Kleinschreibung zaehlt
    SELECT * INTO r FROM estate.fn_resolve_contact('notarin muster');
    IF r.hit_count <> 0 THEN RAISE EXCEPTION 'FAIL [exakt]: abweichende Schreibweise trifft (%)', r.hit_count; END IF;
    RAISE NOTICE 'PASS [exakt]: Name wird exakt verglichen';
END $$;
ROLLBACK;
