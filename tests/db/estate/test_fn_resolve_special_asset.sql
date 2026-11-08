-- ============================================================
-- test_fn_resolve_special_asset -- Resolver Beschreibung (exakt) + optional Typ: 0 / 1 / >1 Treffer
--   Gesetz: id nur bei genau einem Treffer (sonst NULL), hit_count immer, candidates nach id sortiert ([] bei 0).
-- ============================================================
BEGIN;
DO $$
DECLARE
    r        RECORD;
    v_solo   BIGINT;
    v_car    BIGINT;
    v_pet    BIGINT;
BEGIN
    INSERT INTO estate.special_assets (asset_type, description) VALUES ('vehicle', 'Einzelstueck Beispiel') RETURNING id INTO v_solo;
    INSERT INTO estate.special_assets (asset_type, description) VALUES ('vehicle', 'Doppelbeschreibung') RETURNING id INTO v_car;
    INSERT INTO estate.special_assets (asset_type, description) VALUES ('pet', 'Doppelbeschreibung') RETURNING id INTO v_pet;

    SELECT * INTO r FROM estate.fn_resolve_special_asset('Gibt es nicht');
    IF r.id IS NOT NULL OR r.hit_count <> 0 OR r.candidates <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [0 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [0 Treffer]: id NULL, hit_count 0, candidates []';

    SELECT * INTO r FROM estate.fn_resolve_special_asset('Einzelstueck Beispiel');
    IF r.id IS DISTINCT FROM v_solo OR r.hit_count <> 1 OR jsonb_array_length(r.candidates) <> 1 THEN
        RAISE EXCEPTION 'FAIL [1 Treffer]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    RAISE NOTICE 'PASS [1 Treffer]: id gesetzt';

    SELECT * INTO r FROM estate.fn_resolve_special_asset('Doppelbeschreibung');
    IF r.id IS NOT NULL OR r.hit_count <> 2 OR (r.candidates->0->>'id')::bigint <> v_car
       OR (r.candidates->1->>'id')::bigint <> v_pet THEN
        RAISE EXCEPTION 'FAIL [>1 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [>1 Treffer]: id NULL, hit_count 2, Kandidaten nach id';

    SELECT * INTO r FROM estate.fn_resolve_special_asset('Doppelbeschreibung', 'pet');
    IF r.id IS DISTINCT FROM v_pet OR r.hit_count <> 1 THEN
        RAISE EXCEPTION 'FAIL [Typ]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    SELECT * INTO r FROM estate.fn_resolve_special_asset('Doppelbeschreibung', '');
    IF r.hit_count <> 2 THEN RAISE EXCEPTION 'FAIL [leerer Typ]: hit_count=%', r.hit_count; END IF;
    SELECT * INTO r FROM estate.fn_resolve_special_asset('Doppelbeschreibung', 'firearm');
    IF r.hit_count <> 0 OR r.id IS NOT NULL THEN RAISE EXCEPTION 'FAIL [falscher Typ]: hit_count=%', r.hit_count; END IF;
    RAISE NOTICE 'PASS [Typ]: filtert, leer = ohne Filter, falscher Typ = 0';
END $$;
ROLLBACK;
