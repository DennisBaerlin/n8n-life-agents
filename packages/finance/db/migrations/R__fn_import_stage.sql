-- ============================================================
-- fn_import_stage (Staging-Write — KEIN HITL: Staging ist keine Domaenen-Daten)
--   Legt einen Batch an (oder erweitert einen bestehenden) und validiert sofort. Zahl-Felder
--   werden beim Insert via fn_import_normalize_payload kanonisiert (deutsche Schreibweise ->
--   plain), damit der spaetere ::numeric-Cast nie an "4.200,50" scheitert.
--   Payload p: { batch_id (opt — weglassen = neuer Batch), source (chat|vision|csv, def chat),
--                rows: [ {entity_type, ...raw payload, NAMEN statt IDs} ] }
--   Hygiene: der 7-Tage-Verfall laeuft NUR beim Anlegen eines NEUEN Batches (fn_import_sweep) —
--   nicht als Seiteneffekt jedes Stage-Calls (Review A1).
--   Depot-Positionen: das Depot bestimmt fn_import_resolve_depot aus gedruckter Depotnummer/Inhaber, wo moeglich.
--   chat_id (opt, Absender): ein Personenfeld, das GENAU ein Selbstbezug ist ("ich", "me"), wird zum vollen Namen
--   der Person, die gerade chattet. Gesetzliche Rente: hat die Person schon eine aktive, entfaellt die neue
--   'statutory'-Zeile und die Renteninformation des Batches haengt sich an die vorhandene.
--   RUECKGABE: {ok:true, batch_id, staged, total, valid, invalid, errors:[{row_no, entity_type, error, row}]}
--   (row = Kennfelder der Zeile, fn_import_validate)
--   Korrigierbar (rows fehlt/leer, unbekannter entity_type, committeter Batch) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_stage(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_batch   UUID;
    v_source  TEXT := COALESCE(NULLIF(p->>'source',''), 'chat');
    v_row     JSONB;
    v_type    TEXT;
    v_next    INT;
    v_first   INT;
    v_stock   RECORD;
    v_staged  INT := 0;
    v_summary JSONB;
    v_chat    TEXT := NULLIF(p->>'chat_id', '');
    v_srow    RECORD;
    v_field   TEXT;
    v_self    RECORD;
    v_owner   TEXT;
    v_hits    INT;
    v_exist   TEXT;
    v_exist_id INT;
BEGIN
    IF jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'rows') = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'rows must be a non-empty array');
    END IF;
    IF v_source NOT IN ('chat','vision','csv') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'source must be chat|vision|csv');
    END IF;

    -- alle Typen VOR dem Insert pruefen (alles-oder-nichts auch beim Stagen)
    FOR v_row IN SELECT * FROM jsonb_array_elements(p->'rows') LOOP
        v_type := v_row->>'entity_type';
        IF v_type IS NULL OR v_type NOT IN
           ('account','stock_buy','insurance','pension','recurring_payment',
            'real_estate','savings_goal','loan','pension_statement') THEN
            RETURN jsonb_build_object('ok', false,
                'reason', format('unknown entity_type "%s" — allowed: account, stock_buy, insurance, pension, recurring_payment, real_estate, savings_goal, loan, pension_statement', COALESCE(v_type,'<null>')));
        END IF;
    END LOOP;

    IF NULLIF(p->>'batch_id','') IS NOT NULL THEN
        -- Phase B: Modell-Eingabe -> Form-Guard als {ok:false} statt Cast-RAISE
        IF p->>'batch_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', format('batch_id must be the UUID of an earlier staging call (or omitted for a new batch), got %L', p->>'batch_id'));
        END IF;
        v_batch := (p->>'batch_id')::uuid;
        IF EXISTS (SELECT 1 FROM finance.import_staging
                   WHERE batch_id = v_batch AND status = 'committed') THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'this batch is already committed — start a new one (omit batch_id)');
        END IF;
    ELSE
        v_batch := gen_random_uuid();
        PERFORM finance.fn_import_sweep(7);   -- GC nur am natuerlichen Punkt: neuer Batch (Review A1)
    END IF;

    SELECT COALESCE(MAX(row_no), 0) INTO v_next
    FROM finance.import_staging WHERE batch_id = v_batch;
    v_first := v_next + 1;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p->'rows') LOOP
        v_next := v_next + 1;
        v_staged := v_staged + 1;
        INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, source)
        VALUES (v_batch, v_next, v_row->>'entity_type',
                finance.fn_import_normalize_payload(v_row->>'entity_type', (v_row - 'entity_type')), v_source);
    END LOOP;

    -- Depot der NEUEN Positionen aus gedruckter Depotnummer/Inhaber (fn_import_resolve_depot) statt geratenem Namen;
    -- nach dem Insert-Loop, damit auch eine spaeter im Batch stehende Depot-Konto-Zeile zaehlt. Nur hier, nie in
    -- fn_import_update_row (eine Korrektur des Nutzers bleibt stehen).
    FOR v_stock IN
        SELECT s.id, finance.fn_import_resolve_depot(v_batch, s.payload) AS r FROM finance.import_staging s
        WHERE s.batch_id = v_batch AND s.row_no >= v_first AND s.entity_type = 'stock_buy'
    LOOP
        IF v_stock.r IS NOT NULL THEN
            UPDATE finance.import_staging SET payload = payload || jsonb_build_object('depot', v_stock.r->>'depot')
            WHERE id = v_stock.id;
        END IF;
    END LOOP;

    -- Selbstbezug (Renteninformation-Plan 2026-10-26): ein Personenfeld "ich"/"mein"/"me"/"나" meint die Person, die
    -- gerade chattet. Erkannt ohne eigene Wortliste: der Resolver loest den Wert NUR mit chat_id auf (core.fn_resolve_person,
    -- core:V033). Ersetzt durch den vollen Namen -> Validate/Commit brauchen den Absender nie (Batch kennt ihn nicht).
    IF v_chat IS NOT NULL THEN
        FOR v_srow IN SELECT s.id, s.entity_type, s.payload FROM finance.import_staging s
                      WHERE s.batch_id = v_batch AND s.row_no >= v_first LOOP
            v_field := finance.fn_import_person_field(v_srow.entity_type);
            CONTINUE WHEN v_field IS NULL OR NULLIF(trim(COALESCE(v_srow.payload->>v_field, '')), '') IS NULL;
            SELECT r.full_name, r.hit_count INTO v_self FROM core.fn_resolve_person(v_srow.payload->>v_field, v_chat) r;
            IF v_self.hit_count = 1 AND (SELECT r.hit_count FROM core.fn_resolve_person(v_srow.payload->>v_field) r) = 0 THEN
                UPDATE finance.import_staging SET payload = jsonb_set(payload, ARRAY[v_field], to_jsonb(v_self.full_name))
                WHERE id = v_srow.id;
            END IF;
        END LOOP;
    END IF;

    -- Eine aktive gesetzliche Rente je Person (UNIQUE finance_pension_statutory_uq): bringt der Bescheid des
    -- Folgejahres wieder eine 'statutory'-Zeile mit, entfaellt sie und die Renteninformation des Batches haengt sich an
    -- die vorhandene Rente (Historie statt Dublette). Eigentuemer wie im Commit: Name -> Slug, leer = Haushalt.
    FOR v_srow IN SELECT s.id, s.payload FROM finance.import_staging s
                  WHERE s.batch_id = v_batch AND s.row_no >= v_first AND s.entity_type = 'pension'
                    AND s.payload->>'pension_type' = 'statutory' LOOP
        v_owner := NULL; v_hits := 1;
        IF NULLIF(trim(COALESCE(v_srow.payload->>'owner_person', '')), '') IS NOT NULL THEN
            SELECT r.person_id, r.hit_count INTO v_owner, v_hits FROM core.fn_resolve_person(v_srow.payload->>'owner_person') r;
        END IF;
        CONTINUE WHEN v_hits IS DISTINCT FROM 1;   -- unklare Person: validate_row meldet es
        -- vorhandene Rente: die der Person, sonst (Bescheid mit Namen, Rente ohne Person erfasst) die EINE des Haushalts
        v_exist := NULL; v_exist_id := NULL;
        SELECT id, name INTO v_exist_id, v_exist FROM finance.pension
        WHERE pension_type = 'statutory' AND status = 'active' AND owner_person_id IS NOT DISTINCT FROM v_owner;
        IF v_exist_id IS NULL AND v_owner IS NOT NULL THEN
            SELECT id, name INTO v_exist_id, v_exist FROM finance.pension
            WHERE pension_type = 'statutory' AND status = 'active' AND owner_person_id IS NULL;
        END IF;
        CONTINUE WHEN v_exist_id IS NULL;
        -- per id statt Name: zwei Personen duerfen gleichnamige gesetzliche Renten haben (fn_resolve_pension waere mehrdeutig)
        UPDATE finance.import_staging
           SET payload = payload || jsonb_build_object('pension', v_exist, 'pension_id', v_exist_id)
        WHERE batch_id = v_batch AND entity_type = 'pension_statement' AND row_no >= v_first
          AND lower(trim(payload->>'pension')) = lower(trim(v_srow.payload->>'name'));
        DELETE FROM finance.import_staging WHERE id = v_srow.id;
        v_staged := v_staged - 1;
    END LOOP;

    v_summary := finance.fn_import_validate(v_batch);

    RETURN jsonb_build_object(
        'ok', true, 'batch_id', v_batch, 'staged', v_staged,
        'total',   v_summary->'total',
        'valid',   v_summary->'valid',
        'invalid', v_summary->'invalid',
        'errors',  v_summary->'errors');
END;
$$;
