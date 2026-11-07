-- ============================================================
-- test_fn_resolve_provider_contract -- Resolver Anbieter (exakt) + optional Kategorie: 0 / 1 / >1 Treffer
--   Gesetz: id nur bei genau einem Treffer (sonst NULL), hit_count immer, candidates nach id sortiert ([] bei 0).
-- ============================================================
BEGIN;
DO $$
DECLARE
    r        RECORD;
    v_solo   BIGINT;
    v_power  BIGINT;
    v_phone  BIGINT;
BEGIN
    INSERT INTO estate.provider_contracts (category, provider) VALUES ('other', 'Einzelanbieter') RETURNING id INTO v_solo;
    INSERT INTO estate.provider_contracts (category, provider) VALUES ('utilities', 'Doppelanbieter') RETURNING id INTO v_power;
    INSERT INTO estate.provider_contracts (category, provider) VALUES ('telecom', 'Doppelanbieter') RETURNING id INTO v_phone;

    SELECT * INTO r FROM estate.fn_resolve_provider_contract('Gibt es nicht');
    IF r.id IS NOT NULL OR r.hit_count <> 0 OR r.candidates <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [0 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [0 Treffer]: id NULL, hit_count 0, candidates []';

    SELECT * INTO r FROM estate.fn_resolve_provider_contract('Einzelanbieter');
    IF r.id IS DISTINCT FROM v_solo OR r.hit_count <> 1 OR jsonb_array_length(r.candidates) <> 1 THEN
        RAISE EXCEPTION 'FAIL [1 Treffer]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    RAISE NOTICE 'PASS [1 Treffer]: id gesetzt';

    SELECT * INTO r FROM estate.fn_resolve_provider_contract('Doppelanbieter');
    IF r.id IS NOT NULL OR r.hit_count <> 2 OR (r.candidates->0->>'id')::bigint <> v_power
       OR (r.candidates->1->>'id')::bigint <> v_phone THEN
        RAISE EXCEPTION 'FAIL [>1 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [>1 Treffer]: id NULL, hit_count 2, Kandidaten nach id';

    SELECT * INTO r FROM estate.fn_resolve_provider_contract('Doppelanbieter', 'telecom');
    IF r.id IS DISTINCT FROM v_phone OR r.hit_count <> 1 THEN
        RAISE EXCEPTION 'FAIL [Kategorie]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    SELECT * INTO r FROM estate.fn_resolve_provider_contract('Doppelanbieter', '');
    IF r.hit_count <> 2 THEN RAISE EXCEPTION 'FAIL [leere Kategorie]: hit_count=%', r.hit_count; END IF;
    SELECT * INTO r FROM estate.fn_resolve_provider_contract('Doppelanbieter', 'media');
    IF r.hit_count <> 0 OR r.id IS NOT NULL THEN RAISE EXCEPTION 'FAIL [falsche Kategorie]: hit_count=%', r.hit_count; END IF;
    RAISE NOTICE 'PASS [Kategorie]: filtert, leer = ohne Filter, falsche Kategorie = 0';
END $$;
ROLLBACK;
