-- ============================================================
-- fn_set_asset_classes (ATOMIC WRITE) -- Anlageklassen mehrerer Depot-Positionen in EINEM Schritt setzen
--   Owner-Entscheid 2026-10-23: die Anlageklasse wird in der Finanzplanung geklaert -> der Finanzberater (und der
--   Buchhalter) ordnet alle offenen Positionen mit EINER Karte zu. Setzt NUR asset_class (Stammdatum), nie Bestand,
--   Einstand oder Buchungen. Keine zweite Pruef-Logik: je Zeile fn_find_holding (Depot + Position) und
--   fn_set_holding({holding_id, asset_class}) (Format-Pruefung lowercase snake). Reservierter Key
--   outside_plan = "bewusst ausserhalb des Haushaltsplans" (z. B. Kinder-Depot; fn_advisor_review meldet ihn nicht).
--   Eingabe jsonb: { assignments: [ {depot_name, position (Symbol oder ISIN), asset_class}, ... ] } (1..50)
--   Atomar: ALLE Zeilen werden zuerst aufgeloest/geprueft (Position unbekannt/mehrdeutig, Format, doppelte Position)
--   -> eine Ablehnung = KEIN Write, {ok:false, reason, errors:[{index, reason, candidates?}], candidates (alle, fuer das Gate)}.
--   RUECKGABE {ok:true, updated:[{holding_id, name, depot_name, asset_class_before, asset_class}], card_lines}
--   card_lines = je Position eine Kartenzeile (Name, Depot, alt -> neu) fuer das Gate (core.fn_dry_run-Probelauf).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_asset_classes(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_a       JSONB;
    v_i       INT := 0;
    v_find    JSONB;
    v_cls     TEXT;
    v_before  TEXT;
    v_errors  JSONB := '[]'::jsonb;
    v_plan    JSONB := '[]'::jsonb;
    v_ids     INT[] := '{}';
    v_r       JSONB;
    v_card    JSONB := '[]'::jsonb;
    v_x       JSONB;
BEGIN
    IF jsonb_typeof(p->'assignments') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'assignments') = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'assignments must be a non-empty list of {depot_name, position, asset_class}');
    END IF;
    IF jsonb_array_length(p->'assignments') > 50 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'at most 50 positions per call');
    END IF;

    -- Pass 1: alles aufloesen und pruefen, nichts schreiben
    FOR v_a IN SELECT * FROM jsonb_array_elements(p->'assignments') LOOP
        v_i := v_i + 1;
        v_cls := lower(NULLIF(btrim(COALESCE(v_a->>'asset_class', '')), ''));
        v_find := finance.fn_find_holding(jsonb_build_object('depot_name', v_a->>'depot_name', 'position', v_a->>'position'));
        IF (v_find->>'ok')::boolean IS DISTINCT FROM true THEN
            v_errors := v_errors || jsonb_build_array(jsonb_build_object('index', v_i, 'reason', v_find->>'reason',
                                                                         'candidates', COALESCE(v_find->'candidates', '[]'::jsonb)));
            CONTINUE;
        END IF;
        IF v_cls IS NULL OR v_cls !~ '^[a-z0-9_]+$' THEN
            v_errors := v_errors || jsonb_build_array(jsonb_build_object('index', v_i,
                'reason', format('asset_class for "%s" must be a lowercase key (letters/digits/underscore, e.g. sp500 or outside_plan), got "%s"',
                                 v_find->>'name', COALESCE(v_a->>'asset_class', ''))));
            CONTINUE;
        END IF;
        IF (v_find->>'holding_id')::int = ANY (v_ids) THEN
            v_errors := v_errors || jsonb_build_array(jsonb_build_object('index', v_i,
                'reason', format('position "%s" appears twice in this list', v_find->>'name')));
            CONTINUE;
        END IF;
        v_ids := v_ids || (v_find->>'holding_id')::int;
        SELECT asset_class INTO v_before FROM finance.depot_holdings WHERE id = (v_find->>'holding_id')::int;
        v_plan := v_plan || jsonb_build_array(jsonb_build_object('holding_id', (v_find->>'holding_id')::int,
            'name', v_find->>'name', 'depot_name', v_find->>'depot_name', 'asset_class_before', v_before, 'asset_class', v_cls));
    END LOOP;

    IF jsonb_array_length(v_errors) > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', (SELECT string_agg('#' || (e->>'index') || ': ' || (e->>'reason'), '; ') FROM jsonb_array_elements(v_errors) e),
            'errors', v_errors,
            'candidates', (SELECT COALESCE(jsonb_agg(DISTINCT c), '[]'::jsonb)
                             FROM jsonb_array_elements(v_errors) e, jsonb_array_elements(COALESCE(e->'candidates', '[]'::jsonb)) c));
    END IF;

    -- Pass 2: schreiben ueber die bestehende Write-fn (eine Adresse fuer Format + Update)
    FOR v_x IN SELECT * FROM jsonb_array_elements(v_plan) LOOP
        v_r := finance.fn_set_holding(jsonb_build_object('holding_id', (v_x->>'holding_id')::int, 'asset_class', v_x->>'asset_class'));
        IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'fn_set_holding rejected holding %: %', v_x->>'holding_id', v_r->>'reason';   -- Pass 1 prueft dasselbe
        END IF;
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'raw', 'value',
            core.fn_ui_tpl(CASE WHEN v_x->>'asset_class' = 'outside_plan' THEN 'finance.tpl.asset_class_outside'
                                WHEN v_x->>'asset_class_before' IS NULL THEN 'finance.tpl.asset_class_set'
                                ELSE 'finance.tpl.asset_class_change' END,
                           jsonb_build_object('name', v_x->>'name', 'depot', v_x->>'depot_name',
                                              'from', COALESCE(v_x->>'asset_class_before', ''), 'to', v_x->>'asset_class'))));
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'updated', v_plan, 'card_lines', v_card);
END;
$$;
