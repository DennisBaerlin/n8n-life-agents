-- ============================================================
-- test_fn_resolve_digital_account -- Resolver Anbieter (exakt) + optional Nutzername: 0 / 1 / >1 Treffer
--   Gesetz: id nur bei genau einem Treffer (sonst NULL), hit_count immer, candidates nach id sortiert ([] bei 0).
--   Zwei Konten beim selben Anbieter disambiguiert der Nutzername.
-- ============================================================
BEGIN;
DO $$
DECLARE
    r      RECORD;
    v_a    BIGINT;
    v_b    BIGINT;
    v_solo BIGINT;
BEGIN
    INSERT INTO estate.digital_accounts (category, provider, username) VALUES ('email', 'Beispielmail', 'a.muster') RETURNING id INTO v_a;
    INSERT INTO estate.digital_accounts (category, provider, username) VALUES ('email', 'Beispielmail', 'b.muster') RETURNING id INTO v_b;
    INSERT INTO estate.digital_accounts (category, provider) VALUES ('cloud', 'Einzelwolke') RETURNING id INTO v_solo;

    SELECT * INTO r FROM estate.fn_resolve_digital_account('Gibt es nicht');
    IF r.id IS NOT NULL OR r.hit_count <> 0 OR r.candidates <> '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL [0 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [0 Treffer]: id NULL, hit_count 0, candidates []';

    SELECT * INTO r FROM estate.fn_resolve_digital_account('Einzelwolke');
    IF r.id IS DISTINCT FROM v_solo OR r.hit_count <> 1 OR jsonb_array_length(r.candidates) <> 1 THEN
        RAISE EXCEPTION 'FAIL [1 Treffer]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    RAISE NOTICE 'PASS [1 Treffer]: id gesetzt';

    SELECT * INTO r FROM estate.fn_resolve_digital_account('Beispielmail');
    IF r.id IS NOT NULL OR r.hit_count <> 2 OR (r.candidates->0->>'id')::bigint <> v_a
       OR (r.candidates->1->>'id')::bigint <> v_b THEN
        RAISE EXCEPTION 'FAIL [>1 Treffer]: id=%, hit_count=%, candidates=%', r.id, r.hit_count, r.candidates;
    END IF;
    RAISE NOTICE 'PASS [>1 Treffer]: id NULL, hit_count 2, Kandidaten nach id';

    SELECT * INTO r FROM estate.fn_resolve_digital_account('Beispielmail', 'b.muster');
    IF r.id IS DISTINCT FROM v_b OR r.hit_count <> 1 THEN
        RAISE EXCEPTION 'FAIL [Nutzername]: id=%, hit_count=%', r.id, r.hit_count;
    END IF;
    SELECT * INTO r FROM estate.fn_resolve_digital_account('Beispielmail', '');
    IF r.hit_count <> 2 THEN RAISE EXCEPTION 'FAIL [leerer Nutzername]: hit_count=%', r.hit_count; END IF;
    SELECT * INTO r FROM estate.fn_resolve_digital_account('Beispielmail', 'c.muster');
    IF r.hit_count <> 0 OR r.id IS NOT NULL THEN RAISE EXCEPTION 'FAIL [falscher Nutzername]: hit_count=%', r.hit_count; END IF;
    RAISE NOTICE 'PASS [Nutzername]: filtert, leer = ohne Filter, falscher Nutzername = 0';
END $$;
ROLLBACK;
