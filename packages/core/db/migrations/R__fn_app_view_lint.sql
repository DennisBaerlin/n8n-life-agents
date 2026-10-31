-- ============================================================
-- core.fn_app_view_lint(p_view jsonb, p_neutral_keys text[], p_undated_keys text[]) — Regel-Pruefer eines Mini-App-
--   View-Modells v1 (READ, rein; docs/package-contract.md §3.12 Design rules, UX-Gesamtkonzept 2026-10-31 Abschnitt 11)
--   Eine Zeile je Verstoss {rule, path}; 0 Zeilen = die Seite haelt die Regeln. Pflicht-Assertion jedes
--   test_fn_app_screen_* (auf dem Fixture-Haushalt tests/util/util_app_household.sql) und Abnahme-Werkzeug fuer echte
--   View-Modelle vom Live-System (deshalb im Produktiv-Schema, nicht im Test-Code).
--   Regeln:
--     L1 section.value nicht null bei <= 1 Zeile          L2 pill.state oder progress.state = 'ok' (nie gruen)
--     L3 neutral-Pille, deren tpl-Key nicht in p_neutral_keys steht (der Handler-Test gibt seine erlaubten Keys frei:
--        neutral nur, wenn der Text sagt, was fehlt und wer es beheben kann)
--     L4 section.value = hero.value (Betrag + Waehrung aus money oder dem einzigen money-Parameter eines tpl; sign egal)
--     L5 details > 8 Zeilen
--     L6 doppelter Fakt auf der Seite: dasselbe benannte Ding (roher Namens-String als Anker: das Zeilen-Label bzw. das
--        Label einer Detailzeile) mit demselben Betrag in zwei Abschnitten — egal ob als Zeilenwert, als Detailwert
--        oder als Betrag in sub/Detail-Texten der Zeile; Betrag 0 zaehlt nicht; tpl-Labels („Gehen ab“ je Konto) sind
--        kein Anker (keine falschen Treffer bei Abschnitten je Konto)
--     L7 warn/alert-Pille ohne money/date/month in den Text-Parametern, ausser ihr Key steht in p_undated_keys
--        (echte Handlungsaufforderung ohne Zahl, z. B. „Kurs fehlt“)
--     L8 section.value nicht null, obwohl eine Zeile gap:true traegt (Summe waere unvollstaendig)
--     shape  kaputte Form (View kein Objekt, sections/items/details kein Array, Element kein Objekt, Betrag keine
--            Zahl) mit Pfad; nie eine Exception, die uebrigen Regeln laufen weiter
--   path: 0-basiert wie im JSON, z. B. sections[2].items[0].pill
--   Seiten-uebergreifende Doppelung (dieselbe Zahl auf zwei Tabs) prueft diese fn nicht (Abnahme auf den gerenderten
--   Seiten, Checkliste Abschnitt 12).
--   RUECKGABE: TABLE(rule text, path text)
--   Tests: tests/db/core/test_fn_app_view_lint.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_view_lint(p_view jsonb, p_neutral_keys text[] DEFAULT '{}',
                                                 p_undated_keys text[] DEFAULT '{}')
RETURNS TABLE(rule text, path text)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_sec    jsonb;
    v_si     bigint;
    v_it     jsonb;
    v_ii     bigint;
    v_d      jsonb;
    v_di     bigint;
    v_sp     text;
    v_ip     text;
    v_n      int;
    v_amt    numeric;
    v_cur    text;
    v_hamt   numeric;
    v_hcur   text;
    v_pill   jsonb;
    v_facts  jsonb := '[]'::jsonb;   -- [{s, anchor, amt, cur, path}] fuer L6
    v_badm   CONSTANT jsonpath := 'strict $.** ? (@.kind == "money" && @.value.type() != "number" && @.value.type() != "null")';
BEGIN
    IF jsonb_typeof(p_view) IS DISTINCT FROM 'object' THEN
        rule := 'shape'; path := '$'; RETURN NEXT; RETURN;
    END IF;
    IF p_view ? 'sections' AND jsonb_typeof(p_view->'sections') IS DISTINCT FROM 'array' THEN
        rule := 'shape'; path := 'sections'; RETURN NEXT; RETURN;
    END IF;

    -- Ein Betrag ist eine JSON-Zahl (core.fn_ui_money) oder null; alles andere ist shape an Hero/Abschnitt/Zeile, und
    -- gerechnet wird nur mit echten Zahlen (keine Cast-Exception, die uebrigen Regeln laufen weiter).
    IF jsonb_path_exists(COALESCE(p_view->'hero', 'null'::jsonb), v_badm) THEN rule := 'shape'; path := 'hero'; RETURN NEXT; END IF;

    IF p_view->'hero'->'value'->>'kind' = 'money' AND jsonb_typeof(p_view->'hero'->'value'->'value') = 'number' THEN
        v_hamt := (p_view->'hero'->'value'->>'value')::numeric;
        v_hcur := p_view->'hero'->'value'->>'currency';
    END IF;

    FOR v_sec, v_si IN SELECT e, o - 1 FROM jsonb_array_elements(COALESCE(p_view->'sections', '[]'::jsonb)) WITH ORDINALITY AS t(e, o) LOOP
        v_sp := format('sections[%s]', v_si);
        IF jsonb_typeof(v_sec) IS DISTINCT FROM 'object' THEN
            rule := 'shape'; path := v_sp; RETURN NEXT; CONTINUE;
        END IF;
        IF v_sec ? 'items' AND jsonb_typeof(v_sec->'items') IS DISTINCT FROM 'array' THEN
            rule := 'shape'; path := v_sp || '.items'; RETURN NEXT; CONTINUE;
        END IF;
        v_n := jsonb_array_length(COALESCE(v_sec->'items', '[]'::jsonb));

        IF jsonb_typeof(COALESCE(v_sec->'value', 'null'::jsonb)) <> 'null' THEN
            IF v_n <= 1 THEN rule := 'L1'; path := v_sp || '.value'; RETURN NEXT; END IF;
            IF jsonb_path_exists(v_sec->'value', v_badm) THEN rule := 'shape'; path := v_sp || '.value'; RETURN NEXT; END IF;
            -- Betrag der Summe: money direkt, sonst der EINZIGE money-Parameter eines tpl
            SELECT CASE WHEN count(*) = 1 THEN min((s.m->'value')::text)::numeric END,
                   CASE WHEN count(*) = 1 THEN min(s.m->>'currency') END
              INTO v_amt, v_cur
              FROM (SELECT v_sec->'value' AS m WHERE v_sec->'value'->>'kind' = 'money'
                    UNION ALL
                    SELECT p.value FROM jsonb_each(CASE WHEN v_sec->'value'->>'kind' = 'tpl' AND jsonb_typeof(v_sec->'value'->'params') = 'object'
                                                        THEN v_sec->'value'->'params' ELSE '{}'::jsonb END) p
                     WHERE jsonb_typeof(p.value) = 'object' AND p.value->>'kind' = 'money') s
             WHERE jsonb_typeof(s.m->'value') = 'number';
            IF v_amt IS NOT NULL AND v_amt = v_hamt AND v_cur IS NOT DISTINCT FROM v_hcur THEN
                rule := 'L4'; path := v_sp || '.value'; RETURN NEXT;
            END IF;
            IF jsonb_path_exists(COALESCE(v_sec->'items', '[]'::jsonb), 'strict $[*] ? (@.gap == true)') THEN
                rule := 'L8'; path := v_sp || '.value'; RETURN NEXT;
            END IF;
        END IF;

        FOR v_it, v_ii IN SELECT e, o - 1 FROM jsonb_array_elements(COALESCE(v_sec->'items', '[]'::jsonb)) WITH ORDINALITY AS t(e, o) LOOP
            v_ip := format('%s.items[%s]', v_sp, v_ii);
            IF jsonb_typeof(v_it) IS DISTINCT FROM 'object' THEN
                rule := 'shape'; path := v_ip; RETURN NEXT; CONTINUE;
            END IF;
            IF jsonb_path_exists(v_it, v_badm) THEN rule := 'shape'; path := v_ip; RETURN NEXT; END IF;

            v_pill := v_it->'pill';
            IF jsonb_typeof(v_pill) = 'object' THEN
                IF v_pill->>'state' = 'ok' THEN rule := 'L2'; path := v_ip || '.pill'; RETURN NEXT; END IF;
                IF v_pill->>'state' = 'neutral'
                   AND (v_pill->'text'->>'value' IS NULL OR NOT (v_pill->'text'->>'value' = ANY (COALESCE(p_neutral_keys, '{}')))) THEN
                    rule := 'L3'; path := v_ip || '.pill'; RETURN NEXT;
                END IF;
                IF v_pill->>'state' IN ('warn', 'alert')
                   AND NOT COALESCE(v_pill->'text'->>'value' = ANY (COALESCE(p_undated_keys, '{}')), false)
                   AND NOT jsonb_path_exists(COALESCE(v_pill->'text', 'null'::jsonb),
                                             'strict $.** ? (@.kind == "money" || @.kind == "date" || @.kind == "month")') THEN
                    rule := 'L7'; path := v_ip || '.pill'; RETURN NEXT;
                END IF;
            END IF;
            IF jsonb_typeof(v_it->'progress') = 'object' AND v_it->'progress'->>'state' = 'ok' THEN
                rule := 'L2'; path := v_ip || '.progress'; RETURN NEXT;
            END IF;
            IF v_it ? 'details' AND jsonb_typeof(v_it->'details') NOT IN ('array', 'null') THEN
                rule := 'shape'; path := v_ip || '.details'; RETURN NEXT;
            ELSIF jsonb_typeof(v_it->'details') = 'array' AND jsonb_array_length(v_it->'details') > 8 THEN
                rule := 'L5'; path := v_ip || '.details'; RETURN NEXT;
            END IF;

            -- L6-Fakten: benannte Zeile (roher String = ein Ding der Daten: Konto, Ziel, Position)
            IF jsonb_typeof(v_it->'label') = 'string' THEN
                -- Zeilenwert + Betraege in sub und in tpl-Texten der Details, alle am Zeilen-Namen verankert
                SELECT v_facts || COALESCE(jsonb_agg(jsonb_build_object('s', v_si, 'anchor', v_it->>'label',
                           'amt', (f.m->>'value')::numeric, 'cur', f.m->>'currency', 'path', v_ip)), '[]'::jsonb)
                  INTO v_facts
                  FROM (SELECT v_it->'value' AS m
                        UNION ALL
                        SELECT q.m FROM jsonb_path_query(jsonb_build_array(v_it->'sub',
                                          (SELECT COALESCE(jsonb_agg(d.e), '[]'::jsonb)
                                             FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_it->'details') = 'array' THEN v_it->'details' ELSE '[]'::jsonb END) d(e)
                                            WHERE jsonb_typeof(d.e->'label') <> 'string')),
                                        'strict $.** ? (@.kind == "money")') AS q(m)) f
                 WHERE f.m->>'kind' = 'money' AND jsonb_typeof(f.m->'value') = 'number' AND f.m->'value' <> '0'::jsonb;
            END IF;
            -- Detailzeilen mit eigenem Namen (roher String) verankern an diesem Namen
            FOR v_d, v_di IN SELECT e, o - 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_it->'details') = 'array' THEN v_it->'details' ELSE '[]'::jsonb END)
                                    WITH ORDINALITY AS t(e, o) LOOP
                CONTINUE WHEN jsonb_typeof(v_d) IS DISTINCT FROM 'object' OR jsonb_typeof(v_d->'label') <> 'string';
                SELECT v_facts || COALESCE(jsonb_agg(jsonb_build_object('s', v_si, 'anchor', v_d->>'label',
                           'amt', (q.m->>'value')::numeric, 'cur', q.m->>'currency', 'path', format('%s.details[%s]', v_ip, v_di))), '[]'::jsonb)
                  INTO v_facts
                  FROM jsonb_path_query(COALESCE(v_d->'value', 'null'::jsonb), 'strict $.** ? (@.kind == "money")') AS q(m)
                 WHERE jsonb_typeof(q.m->'value') = 'number' AND q.m->'value' <> '0'::jsonb;
            END LOOP;
        END LOOP;
    END LOOP;

    -- L6: jeder Fakt, der in einem frueheren Abschnitt schon einmal steht
    RETURN QUERY
    SELECT DISTINCT 'L6'::text, f->>'path'
      FROM jsonb_array_elements(v_facts) f
     WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(v_facts) g
                    WHERE (g->>'s')::int < (f->>'s')::int
                      AND g->>'anchor' = f->>'anchor'
                      AND (g->>'amt')::numeric = (f->>'amt')::numeric
                      AND g->>'cur' IS NOT DISTINCT FROM f->>'cur');
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_view_lint(jsonb, text[], text[]) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_app_view_lint(jsonb, text[], text[]) FROM context_ro;
    END IF;
END $$;
