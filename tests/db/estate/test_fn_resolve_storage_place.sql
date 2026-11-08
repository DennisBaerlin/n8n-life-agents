-- ============================================================
-- test_fn_resolve_storage_place -- Resolver Name (exakt): 0 / 1 / >1 Treffer
--   Gesetz: id nur bei genau einem Treffer (sonst NULL), hit_count immer, candidates nach id sortiert ([] bei 0).
-- ============================================================
BEGIN;
DO $$
DECLARE
    r      RECORD;
    v_solo BIGINT;
    v_a    BIGINT;
    v_b    BIGINT;
BEGIN
    INSERT INTO estate.storage_places (name, kind) VALUES ('Einzelner Ordner', 'folder') RETURNING id INTO v_solo;
    INSERT INTO estate.storage_places (name, kind) VALUES ('Doppelter Name', 'safe') RETURNING id INTO v_a;
    INSERT INTO estate.storage_places (name, kind) VALUES ('Doppelter Name', 'folder') RETURNING id INTO v_b;

    SELECT * INTO r FROM estate.fn_resolve_storage_place('Gibt es nicht');
    IF r.id IS NOT NULL OR r.hit_count <> 0 OR r.candidates <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [0 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [0 Treffer]: id NULL, hit_count 0, candidates []';

    SELECT * INTO r FROM estate.fn_resolve_storage_place('Einzelner Ordner');
    IF r.id IS DISTINCT FROM v_solo OR r.hit_count <> 1 OR jsonb_array_length(r.candidates) <> 1
       OR (r.candidates->0->>'kind') <> 'folder' THEN
        RAISE EXCEPTION 'FAIL [1 Treffer]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    RAISE NOTICE 'PASS [1 Treffer]: id gesetzt';

    SELECT * INTO r FROM estate.fn_resolve_storage_place('Doppelter Name');
    IF r.id IS NOT NULL OR r.hit_count <> 2 OR (r.candidates->0->>'id')::bigint <> v_a
       OR (r.candidates->1->>'id')::bigint <> v_b THEN
        RAISE EXCEPTION 'FAIL [>1 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [>1 Treffer]: id NULL, hit_count 2, Kandidaten nach id';

    SELECT * INTO r FROM estate.fn_resolve_storage_place('einzelner ordner');
    IF r.hit_count <> 0 THEN RAISE EXCEPTION 'FAIL [exakt]: abweichende Schreibweise trifft (%)', r.hit_count; END IF;
    RAISE NOTICE 'PASS [exakt]: Name wird exakt verglichen';
END $$;
ROLLBACK;
