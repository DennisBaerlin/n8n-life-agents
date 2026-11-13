-- ============================================================
-- fn_get_recurring_candidates (READ, STABLE) -- wiederkehrende Zahlungen aus Zeilen erkennen (Export oder Kontoauszug)
--   Die eine Adresse fuer Rhythmus-Messung, Tageswahl, Reife-Regel ("sicher"), Startdatum und Bekannt-Filter
--   (fn_recurring_known). Konsumenten: fn_get_recurring_suggestions (mode export), fn_import_stage_recurring und
--   fn_get_recurring_suggestion_queue (mode statement; die Queue misst die gespeicherten Termine einer Vorschlagszeile neu).
--   mode export (Zeilen von fn_bank_export_load): nur kind cash, Betrag <> 0, kein legacy_return; Schluessel je Vorzeichen
--   Gegenkonto (Gegen-IBAN = Kontonummer eines anderen aktiven eigenen Kontos bzw. Bondora-Ein-/Auszahlung ->
--   Verrechnungskonto), sonst Gegen-IBAN (fn_iban_strict), sonst Name (die ersten zwei Woerter ohne Ziffern, klein); Name im
--   Vorschlag = Gegenpart wie gedruckt, ohne Gegenpart die ersten drei Woerter ohne Ziffern des Buchungstexts. Ausgaben in
--   Betrags-Clustern +-7,5 % (zeitlich aufeinander folgende Cluster mit je >= 2 Zeilen = Preisstufe, eine Reihe), Einnahmen
--   ohne; mehrere Reihen auf einer IBAN (Zahlungsdienst) -> die IBAN ist kein Schluessel. Reihen unter 2 Terminen,
--   ohne Rhythmus, unter 80 % Treffern oder unreif fallen weg.
--   mode statement (Zeilen des Lese-Modells mit recurring_kind, series, rhythm_hint): zuerst fn_statement_lines_merge;
--   Kategorie-Regel fn_recurring_kind_policy (nie card_purchase/cash/fee_interest; insurance/loan nur als hints);
--   Schluessel = series (klein) + Gegen-IBAN (unterschiedliche IBANs trennen die Reihe); ohne series einmalig = kein
--   Vorschlag. Kein Betrags-Cluster (das Modell gruppiert), keine geteilte IBAN. Reif nach der Export-Regel -> confidence
--   sure; sonst confirm, wenn die Kategorie es erlaubt (other nie): ab 2 Terminen der gemessene Rhythmus, bei einem Termin
--   (oder nicht messbarem Abstand) der rhythm_hint des Modells (Standard monatlich) mit Tag fn_recurring_plausible_day und
--   rhythm_assumed true.
--   Rhythmus aus dem Median-Abstand: week 1/2, month 1/3/6, year 1. Jede Zeile zaehlt zum naechsten Faelligkeitstag des
--   Rasters (month: Tag 1-28 oder -1, meiste Treffer, dann kleinste Abweichung; Phase aus der juengsten Zeile). Treffer =
--   +-3 Tage (week +-2), Reihe gilt bei >= 80 % Treffern. Reif: >= 3 Termine (month 3/6, year: >= 2); aktiv: letzter
--   Termin hoechstens 1,5 Intervalle vor period_last. Mehrere Zeilen am selben Tag einer Reihe = ein Termin mit der Summe.
--   Startdatum = naechster Rastertermin nach dem letzten Termin, nach last_reconciled_at und opening_balance_date des Kontos
--   (kein bestaetigter Monat bekommt eine offene Faelligkeit). Art: transfer (Gegenkonto), household
--   (fn_match_household_holder), sonst payment.
--   plpgsql (late-bound): ruft alphabetisch spaetere fn_iban_strict, fn_match_household_holder, fn_recurring_*,
--   fn_statement_lines_merge.
--   Eingabe p: {account_id (Pflicht), mode (export|statement, def export), period_last (def juengste Zeile), lines[]}.
--   RAISE nur bei unbekanntem mode oder Konto.
--   Rueckgabe: {suggestions:[{name, kind, direction, counterparty_iban?, from_account?, to_account?, from_account_id?,
--   to_account_id?, amount, average_amount, amount_varies, schedule_unit, schedule_interval, schedule_day_of_month,
--   first_payment_date, occurrences, first_date, last_date, dates:[{date, amount}], statement: recurring_kind, confidence,
--   rhythm_assumed, series, creditor_id?, mandate_ref?}] (nach Monatsbetrag absteigend), known_elsewhere:[{name,
--   account_name}], hints:[{kind:'area', area, name}]}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_recurring_candidates(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_mode     TEXT := COALESCE(NULLIF(p->>'mode', ''), 'export');
    v_stmt     BOOLEAN;
    v_acct     finance.accounts%ROWTYPE;
    v_last     DATE;
    v_lines    JSONB;
    v_g        RECORD;
    v_it       JSONB;
    v_clusters JSONB;
    v_cur      JSONB;
    v_mean     NUMERIC;
    v_cnt      INT;
    v_merged   JSONB;
    v_c        JSONB;
    v_ds       DATE[];
    v_gap      NUMERIC;
    v_unit     finance.schedule_unit;
    v_int      INT;
    v_tol      INT;
    v_dom      INT;
    v_lastd    DATE;
    v_fit      JSONB;
    v_n        INT;
    v_fb       INT;
    v_occ      INT;
    v_last_due DATE;
    v_next     DATE;
    v_floor    DATE;
    v_step     INT;
    v_amt      NUMERIC;
    v_avg      NUMERIC;
    v_var      BOOLEAN;
    v_name     TEXT;
    v_iban     TEXT;
    v_mand     TEXT;
    v_other    INT;
    v_sign     INT;
    v_kind     TEXT;
    v_known    JSONB;
    v_pol      JSONB;
    v_conf     TEXT;
    v_assumed  BOOLEAN;
    v_hintr    TEXT;
    v_sugs     JSONB := '[]'::jsonb;
    v_elsewh   JSONB := '[]'::jsonb;
    v_hints    JSONB := '[]'::jsonb;
    v_shared   BOOLEAN;
BEGIN
    IF v_mode NOT IN ('export', 'statement') THEN
        RAISE EXCEPTION 'fn_get_recurring_candidates: unknown mode %', v_mode;
    END IF;
    v_stmt := v_mode = 'statement';
    SELECT * INTO v_acct FROM finance.accounts WHERE id = (p->>'account_id')::int;
    IF v_acct.id IS NULL THEN
        RAISE EXCEPTION 'fn_get_recurring_candidates: account % not found', p->>'account_id';
    END IF;

    -- ---------- Zeilen + Schluessel ----------
    IF v_stmt THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'iban', x.iban, 'other', x.other,
                   'mand', x.mand, 'ser', x.ser, 'kind', x.pol->>'kind', 'hint', x.hint, 'cid', x.cid, 'mref', x.mref,
                   'area', x.pol->>'hint_area',
                   'gk', 's:' || lower(x.ser) || '|' || COALESCE(x.iban, '')) ORDER BY x.d), '[]'::jsonb)
        INTO v_lines
        FROM (
            SELECT y.*, finance.fn_recurring_kind_policy(y.rk) AS pol,
                   (SELECT a.id FROM finance.accounts a
                    WHERE y.iban IS NOT NULL AND a.status = 'active' AND a.id <> v_acct.id AND a.account_number = y.iban
                    ORDER BY a.id LIMIT 1) AS other
            FROM (
                SELECT (l->>'date')::date AS d, round((l->>'amount')::numeric, 2) AS amt, l->>'recurring_kind' AS rk,
                       COALESCE(finance.fn_recurring_clean_name(l->>'counterparty'), finance.fn_recurring_clean_name(l->>'series')) AS nm,
                       finance.fn_recurring_clean_name(l->>'series') AS ser,
                       NULLIF(lower(btrim(COALESCE(l->>'rhythm_hint', ''))), '') AS hint,
                       CASE WHEN finance.fn_iban_strict(l->>'counterparty_iban')
                            THEN finance.fn_normalize_account_number(l->>'counterparty_iban') END AS iban,
                       NULLIF(upper(regexp_replace(COALESCE(l->>'creditor_id', ''), '\s', '', 'g')), '') AS cid,
                       NULLIF(upper(regexp_replace(COALESCE(l->>'mandate_ref', ''), '\s', '', 'g')), '') AS mref,
                       CASE WHEN NULLIF(btrim(l->>'creditor_id'), '') IS NOT NULL AND NULLIF(btrim(l->>'mandate_ref'), '') IS NOT NULL
                            THEN upper(regexp_replace(l->>'creditor_id', '\s', '', 'g')) || '|'
                                 || upper(regexp_replace(l->>'mandate_ref', '\s', '', 'g')) END AS mand
                FROM jsonb_array_elements(finance.fn_statement_lines_merge(p->'lines')) l
                WHERE COALESCE((l->>'amount')::numeric, 0) <> 0
            ) y
        ) x
        WHERE x.ser IS NOT NULL AND x.nm IS NOT NULL
          AND ((x.pol->>'proposable')::boolean OR x.pol ? 'hint_area');

        -- insurance/loan: nur ein Hinweis auf den Bereich (je Name einmal), nie ein Vorschlag
        SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('kind', 'area', 'area', l->>'area', 'name', l->>'nm')), '[]'::jsonb)
        INTO v_hints
        FROM jsonb_array_elements(v_lines) l WHERE l->>'area' IS NOT NULL;
        SELECT COALESCE(jsonb_agg(l ORDER BY (l->>'d')::date), '[]'::jsonb) INTO v_lines
        FROM jsonb_array_elements(v_lines) l WHERE l->>'area' IS NULL;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'iban', x.iban, 'other', x.other,
                   'gk', CASE WHEN x.other IS NOT NULL THEN 'a:' || x.other WHEN x.iban IS NOT NULL THEN 'i:' || x.iban
                              ELSE 'n:' || x.nkey END) ORDER BY x.d), '[]'::jsonb)
        INTO v_lines
        FROM (
            SELECT y.*,
                   COALESCE(CASE WHEN y.sub_kind IN ('deposit', 'withdrawal') THEN v_acct.settlement_account_id END,
                            (SELECT a.id FROM finance.accounts a
                             WHERE y.iban IS NOT NULL AND a.status = 'active' AND a.id <> v_acct.id AND a.account_number = y.iban
                             ORDER BY a.id LIMIT 1)) AS other,
                   (SELECT string_agg(t, ' ' ORDER BY o) FROM (
                        SELECT t, o FROM regexp_split_to_table(lower(y.nm), '[^[:alnum:]]+') WITH ORDINALITY s(t, o)
                        WHERE length(t) >= 2 AND t !~ '[0-9]' ORDER BY o LIMIT 2) z) AS nkey
            FROM (
                -- nie der ganze Verwendungszweck (Kunden-/Vertragsnummern gehen nicht ans Modell)
                SELECT (r->>'date')::date AS d, round((r->>'cash_amount')::numeric, 2) AS amt, r->>'sub_kind' AS sub_kind,
                       COALESCE(NULLIF(btrim(r->>'counterparty'), ''),
                                (SELECT string_agg(w, ' ' ORDER BY o) FROM (
                                     SELECT w, o FROM regexp_split_to_table(btrim(COALESCE(NULLIF(btrim(r->>'purpose'), ''), r->>'name', '')), '\s+')
                                            WITH ORDINALITY s(w, o)
                                     WHERE w <> '' AND w !~ '[0-9]' ORDER BY o LIMIT 3) z)) AS nm,
                       CASE WHEN finance.fn_iban_strict(r->>'counterparty_iban')
                            THEN finance.fn_normalize_account_number(r->>'counterparty_iban') END AS iban
                FROM jsonb_array_elements(p->'lines') r
                WHERE r->>'kind' = 'cash' AND COALESCE((r->>'cash_amount')::numeric, 0) <> 0
                  AND COALESCE(r->>'sub_kind', '') <> 'legacy_return'
            ) y
        ) x
        WHERE x.other IS NOT NULL OR x.iban IS NOT NULL OR x.nkey IS NOT NULL;
    END IF;
    v_last := COALESCE(NULLIF(p->>'period_last', '')::date,
                       (SELECT max((l->>'d')::date) FROM jsonb_array_elements(v_lines) l));

    FOR v_g IN
        SELECT l->>'gk' AS gk, sign((l->>'amt')::numeric)::int AS sg,
               jsonb_agg(l ORDER BY abs((l->>'amt')::numeric), (l->>'d')::date) AS items,
               (SELECT k FROM (SELECT x->>'kind' AS k, count(*) AS n, max((x->>'d')::date) AS md
                               FROM jsonb_array_elements(jsonb_agg(l)) x GROUP BY 1) q ORDER BY q.n DESC, q.md DESC LIMIT 1) AS rk
        FROM jsonb_array_elements(v_lines) l
        GROUP BY 1, 2
        HAVING count(*) >= CASE WHEN v_stmt THEN 1 ELSE 2 END
    LOOP
        v_pol := CASE WHEN v_stmt THEN finance.fn_recurring_kind_policy(v_g.rk) END;
        -- ---------- Betrags-Cluster (nur Export-Ausgaben) ----------
        IF v_g.sg > 0 OR v_stmt THEN
            v_merged := jsonb_build_array(v_g.items);
        ELSE
            v_clusters := '[]'::jsonb; v_cur := '[]'::jsonb; v_mean := NULL; v_cnt := 0;
            FOR v_it IN SELECT e FROM jsonb_array_elements(v_g.items) e LOOP
                IF v_mean IS NULL OR abs(abs((v_it->>'amt')::numeric) - v_mean) <= v_mean * 0.075 THEN
                    v_cnt  := v_cnt + 1;
                    v_mean := COALESCE(v_mean, 0) + (abs((v_it->>'amt')::numeric) - COALESCE(v_mean, 0)) / v_cnt;
                    v_cur  := v_cur || jsonb_build_array(v_it);
                ELSE
                    v_clusters := v_clusters || jsonb_build_array(v_cur);
                    v_cur := jsonb_build_array(v_it); v_cnt := 1; v_mean := abs((v_it->>'amt')::numeric);
                END IF;
            END LOOP;
            v_clusters := v_clusters || jsonb_build_array(v_cur);
            v_merged := '[]'::jsonb;
            FOR v_c IN
                SELECT c FROM jsonb_array_elements(v_clusters) c
                ORDER BY (SELECT min((x->>'d')::date) FROM jsonb_array_elements(c) x)
            LOOP
                IF jsonb_array_length(v_merged) > 0 AND jsonb_array_length(v_c) >= 2
                   AND jsonb_array_length(v_merged->-1) >= 2
                   AND (SELECT max((x->>'d')::date) FROM jsonb_array_elements(v_merged->-1) x)
                       < (SELECT min((x->>'d')::date) FROM jsonb_array_elements(v_c) x) THEN
                    v_merged := jsonb_set(v_merged, ARRAY[(jsonb_array_length(v_merged) - 1)::text], (v_merged->-1) || v_c);
                ELSE
                    v_merged := v_merged || jsonb_build_array(v_c);
                END IF;
            END LOOP;
        END IF;
        v_shared := NOT v_stmt AND (SELECT count(*) FROM jsonb_array_elements(v_merged) c WHERE jsonb_array_length(c) >= 2) > 1;

        FOR v_c IN SELECT c FROM jsonb_array_elements(v_merged) c
                   WHERE jsonb_array_length(c) >= CASE WHEN v_stmt THEN (v_pol->>'min_lines')::int ELSE 2 END LOOP
            -- Zwei Zahlungen am selben Tag an denselben Schluessel = ein Termin mit der Summe
            v_c := (SELECT jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'iban', x.iban, 'other', x.other,
                                                        'mand', x.mand, 'cid', x.cid, 'mref', x.mref, 'hint', x.hint, 'ser', x.ser) ORDER BY x.d)
                    FROM (SELECT (e->>'d')::date AS d, sum((e->>'amt')::numeric) AS amt, min(e->>'nm') AS nm,
                                 min(e->>'iban') AS iban, min(e->>'other') AS other, max(e->>'mand') AS mand,
                                 max(e->>'cid') AS cid, max(e->>'mref') AS mref, max(e->>'hint') AS hint, min(e->>'ser') AS ser
                          FROM jsonb_array_elements(v_c) e GROUP BY 1) x);
            CONTINUE WHEN NOT v_stmt AND jsonb_array_length(v_c) < 2;
            v_ds := ARRAY(SELECT (x->>'d')::date FROM jsonb_array_elements(v_c) x ORDER BY 1);
            v_n := cardinality(v_ds);
            v_lastd := v_ds[v_n];
            v_unit := NULL; v_tol := 3; v_dom := NULL; v_fit := NULL; v_assumed := false; v_conf := 'sure';

            -- ---------- Rhythmus (ab 2 Terminen gemessen) ----------
            IF v_n >= 2 THEN
                SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v_ds[i + 1] - v_ds[i]) INTO v_gap
                FROM generate_series(1, v_n - 1) i;
                IF v_gap BETWEEN 5 AND 9 THEN v_unit := 'week'; v_int := 1; v_tol := 2;
                ELSIF v_gap BETWEEN 12 AND 16 THEN v_unit := 'week'; v_int := 2; v_tol := 2;
                ELSIF v_gap BETWEEN 25 AND 36 THEN v_unit := 'month'; v_int := 1;
                ELSIF v_gap BETWEEN 80 AND 100 THEN v_unit := 'month'; v_int := 3;
                ELSIF v_gap BETWEEN 170 AND 195 THEN v_unit := 'month'; v_int := 6;
                ELSIF v_gap BETWEEN 350 AND 380 THEN v_unit := 'year'; v_int := 1;
                END IF;
            END IF;
            CONTINUE WHEN v_unit IS NULL AND NOT v_stmt;

            IF v_unit = 'month' THEN
                -- Monatstag: die meisten Treffer, dann die kleinste Abweichung (Tage 29/30 landen bei -1)
                SELECT c.dom INTO v_dom
                FROM unnest(ARRAY[-1] || ARRAY(SELECT generate_series(1, 28))) c(dom)
                CROSS JOIN LATERAL (
                    SELECT count(*) FILTER (WHERE q.dist <= v_tol AND q.phase_ok) AS fb, sum(LEAST(q.dist, 16)) AS tot
                    FROM (
                        SELECT nd.dist,
                               ((EXTRACT(YEAR FROM nd.due) * 12 + EXTRACT(MONTH FROM nd.due))::int
                                - (EXTRACT(YEAR FROM ld.due) * 12 + EXTRACT(MONTH FROM ld.due))::int) % v_int = 0 AS phase_ok
                        FROM unnest(v_ds) b(d)
                        CROSS JOIN LATERAL (
                            SELECT g.due, abs(b.d - g.due) AS dist
                            FROM (SELECT CASE WHEN c.dom = -1 THEN (m.m + interval '1 month')::date - 1 ELSE m.m::date + (c.dom - 1) END AS due
                                  FROM (SELECT date_trunc('month', b.d) + make_interval(months => o) AS m FROM generate_series(-1, 1) o) m) g
                            ORDER BY abs(b.d - g.due), g.due LIMIT 1) nd
                        CROSS JOIN LATERAL (
                            SELECT g.due
                            FROM (SELECT CASE WHEN c.dom = -1 THEN (m.m + interval '1 month')::date - 1 ELSE m.m::date + (c.dom - 1) END AS due
                                  FROM (SELECT date_trunc('month', v_lastd) + make_interval(months => o) AS m FROM generate_series(-1, 1) o) m) g
                            ORDER BY abs(v_lastd - g.due), g.due LIMIT 1) ld
                    ) q
                ) s
                ORDER BY s.fb DESC, s.tot, c.dom DESC
                LIMIT 1;
                SELECT jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'due', x.due,
                           'ok', x.dist <= v_tol AND ((EXTRACT(YEAR FROM x.due) * 12 + EXTRACT(MONTH FROM x.due))::int
                                 - (EXTRACT(YEAR FROM ld.due) * 12 + EXTRACT(MONTH FROM ld.due))::int) % v_int = 0)
                           ORDER BY x.d)
                INTO v_fit
                FROM (SELECT (e->>'d')::date AS d, (e->>'amt')::numeric AS amt, e->>'nm' AS nm, nd.due, abs((e->>'d')::date - nd.due) AS dist
                      FROM jsonb_array_elements(v_c) e
                      CROSS JOIN LATERAL (
                          SELECT g.due
                          FROM (SELECT CASE WHEN v_dom = -1 THEN (m.m + interval '1 month')::date - 1 ELSE m.m::date + (v_dom - 1) END AS due
                                FROM (SELECT date_trunc('month', (e->>'d')::date) + make_interval(months => o) AS m FROM generate_series(-1, 1) o) m) g
                          ORDER BY abs((e->>'d')::date - g.due), g.due LIMIT 1) nd) x
                CROSS JOIN LATERAL (
                    SELECT g.due
                    FROM (SELECT CASE WHEN v_dom = -1 THEN (m.m + interval '1 month')::date - 1 ELSE m.m::date + (v_dom - 1) END AS due
                          FROM (SELECT date_trunc('month', v_lastd) + make_interval(months => o) AS m FROM generate_series(-1, 1) o) m) g
                    ORDER BY abs(v_lastd - g.due), g.due LIMIT 1) ld;
            ELSIF v_unit = 'week' THEN
                SELECT jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'due', x.due, 'ok', abs(x.d - x.due) <= v_tol)
                           ORDER BY x.d)
                INTO v_fit
                FROM (SELECT (e->>'d')::date AS d, (e->>'amt')::numeric AS amt, e->>'nm' AS nm,
                             v_lastd - 7 * v_int * round((v_lastd - (e->>'d')::date) / (7.0 * v_int))::int AS due
                      FROM jsonb_array_elements(v_c) e) x;
            ELSIF v_unit = 'year' THEN
                SELECT jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'due', x.due, 'ok', abs(x.d - x.due) <= v_tol)
                           ORDER BY x.d)
                INTO v_fit
                FROM (SELECT (e->>'d')::date AS d, (e->>'amt')::numeric AS amt, e->>'nm' AS nm,
                             (v_lastd - make_interval(years => round((v_lastd - (e->>'d')::date) / 365.25)::int))::date AS due
                      FROM jsonb_array_elements(v_c) e) x;
            END IF;

            IF v_fit IS NOT NULL THEN
                SELECT count(*) FILTER (WHERE (f->>'ok')::boolean),
                       count(DISTINCT (f->>'due')::date) FILTER (WHERE (f->>'ok')::boolean),
                       max((f->>'due')::date) FILTER (WHERE (f->>'ok')::boolean)
                INTO v_fb, v_occ, v_last_due
                FROM jsonb_array_elements(v_fit) f;
                IF v_fb < 0.8 * v_n THEN
                    CONTINUE WHEN NOT v_stmt;
                    v_fit := NULL;   -- Kontoauszug: nicht messbar -> wie ein Termin mit dem Hinweis des Modells
                -- Klammer Pflicht: ein nacktes CASE ... ELSE in ELSIF liest PL/pgSQL als eigenes ELSE
                ELSIF v_occ < (CASE WHEN v_unit = 'year' OR (v_unit = 'month' AND v_int >= 3) THEN 2 ELSE 3 END) THEN
                    CONTINUE WHEN NOT v_stmt;
                    v_conf := 'confirm';
                END IF;
            END IF;

            IF v_fit IS NULL THEN
                -- ein Termin (oder Abstand nicht messbar): Rhythmus-Hinweis des Modells, Standard monatlich
                v_hintr := (SELECT x->>'hint' FROM jsonb_array_elements(v_c) x WHERE x->>'hint' IS NOT NULL
                            ORDER BY (x->>'d')::date DESC LIMIT 1);
                v_unit := CASE WHEN v_hintr = 'yearly' THEN 'year' ELSE 'month' END;
                v_int  := CASE v_hintr WHEN 'quarterly' THEN 3 WHEN 'half_yearly' THEN 6 ELSE 1 END;
                v_tol  := 3;
                v_dom  := CASE WHEN v_unit = 'month' THEN finance.fn_recurring_plausible_day(v_lastd) END;
                v_last_due := CASE WHEN v_unit = 'year' THEN v_lastd
                                   WHEN v_dom = -1 THEN (date_trunc('month', v_lastd) + interval '1 month')::date - 1
                                   ELSE date_trunc('month', v_lastd)::date + (v_dom - 1) END;
                v_occ := v_n;
                v_conf := 'confirm';
                v_assumed := true;
                v_fit := (SELECT jsonb_agg(jsonb_build_object('d', e->>'d', 'amt', e->'amt', 'nm', e->>'nm', 'ok', true)
                                           ORDER BY (e->>'d')::date)
                          FROM jsonb_array_elements(v_c) e WHERE (e->>'d')::date = v_lastd);
            END IF;
            -- other: nie mit angenommenem Rhythmus, ab zwei gemessenen Terminen schon (min_lines 2)
            CONTINUE WHEN v_stmt AND v_conf = 'confirm' AND NOT (v_pol->>'confirm_ok')::boolean
                          AND (v_assumed OR v_pol->>'kind' <> 'other');
            -- aktiv = gemessen am Ende der Zeilen (ein Export, der vor Wochen endete, verliert sonst still seine Zahlungen)
            CONTINUE WHEN v_last - v_last_due
                          > 1.5 * CASE v_unit WHEN 'week' THEN 7 * v_int WHEN 'month' THEN 30.44 * v_int ELSE 365 END;

            -- ---------- Startdatum: naechster Rastertermin nach dem letzten Termin, dem Abgleich und dem Startbetrag ----------
            v_floor := GREATEST(v_last_due, v_acct.last_reconciled_at, v_acct.opening_balance_date);
            v_step := 1;
            LOOP
                v_next := CASE v_unit
                    WHEN 'week' THEN v_last_due + 7 * v_int * v_step
                    WHEN 'year' THEN (v_last_due + make_interval(years => v_step))::date
                    ELSE CASE WHEN v_dom = -1
                              THEN (date_trunc('month', v_last_due) + make_interval(months => v_int * v_step + 1))::date - 1
                              ELSE (date_trunc('month', v_last_due) + make_interval(months => v_int * v_step))::date + (v_dom - 1) END
                    END;
                EXIT WHEN v_next > v_floor;
                v_step := v_step + 1;
            END LOOP;

            SELECT abs((f->>'amt')::numeric), f->>'nm' INTO v_amt, v_name
            FROM jsonb_array_elements(v_fit) f WHERE (f->>'ok')::boolean
            ORDER BY (f->>'d')::date DESC LIMIT 1;
            SELECT round(avg(abs((f->>'amt')::numeric)), 2), max(abs((f->>'amt')::numeric)) - min(abs((f->>'amt')::numeric)) > 0.005
            INTO v_avg, v_var
            FROM jsonb_array_elements(v_fit) f WHERE (f->>'ok')::boolean;
            v_sign  := v_g.sg;
            v_iban  := v_c->0->>'iban';
            v_other := (v_c->0->>'other')::int;
            v_mand  := (SELECT max(x->>'mand') FROM jsonb_array_elements(v_c) x);

            -- ---------- Bekannt-Filter (eine Adresse) ----------
            v_known := finance.fn_recurring_known(jsonb_build_object('account_id', v_acct.id, 'sign', v_sign, 'amount', v_amt,
                           'iban', v_iban, 'shared', v_shared, 'other_account_id', v_other, 'unit', v_unit, 'interval', v_int,
                           'dom', v_dom, 'tol', v_tol, 'mandate', v_mand,
                           'name', COALESCE(v_name, '') || CASE WHEN v_stmt THEN ' ' || COALESCE(v_c->0->>'ser', '') ELSE '' END));
            CONTINUE WHEN (v_known->>'known')::boolean;
            IF v_known ? 'elsewhere' THEN
                v_elsewh := v_elsewh || jsonb_build_array(jsonb_build_object('name', v_name, 'account_name', v_known->>'elsewhere'));
                CONTINUE;
            END IF;

            v_kind := CASE WHEN v_other IS NOT NULL THEN 'transfer'
                           WHEN (finance.fn_match_household_holder(v_name)->>'matched')::boolean THEN 'household'
                           ELSE 'payment' END;
            v_sugs := v_sugs || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'name', v_name, 'kind', v_kind, 'direction', CASE WHEN v_sign > 0 THEN 'income' ELSE 'expense' END,
                'counterparty_iban', CASE WHEN v_kind <> 'transfer' AND NOT v_shared THEN v_iban END,
                'from_account', CASE WHEN v_kind = 'transfer' THEN
                                     (SELECT a.name FROM finance.accounts a WHERE a.id = CASE WHEN v_sign < 0 THEN v_acct.id ELSE v_other END) END,
                'to_account', CASE WHEN v_kind = 'transfer' THEN
                                   (SELECT a.name FROM finance.accounts a WHERE a.id = CASE WHEN v_sign < 0 THEN v_other ELSE v_acct.id END) END,
                'from_account_id', CASE WHEN v_kind = 'transfer' THEN CASE WHEN v_sign < 0 THEN v_acct.id ELSE v_other END END,
                'to_account_id', CASE WHEN v_kind = 'transfer' THEN CASE WHEN v_sign < 0 THEN v_other ELSE v_acct.id END END,
                'amount', v_amt, 'average_amount', v_avg, 'amount_varies', v_var,
                'schedule_unit', v_unit, 'schedule_interval', v_int, 'first_payment_date', v_next,
                'occurrences', v_occ, 'first_date', v_ds[1], 'last_date', v_lastd,
                'dates', (SELECT jsonb_agg(jsonb_build_object('date', x->>'d', 'amount', (x->>'amt')::numeric) ORDER BY (x->>'d')::date)
                          FROM jsonb_array_elements(v_c) x),
                'recurring_kind', CASE WHEN v_stmt THEN v_pol->>'kind' END,
                'confidence', CASE WHEN v_stmt THEN v_conf END,
                'rhythm_assumed', CASE WHEN v_stmt THEN v_assumed END,
                'series', CASE WHEN v_stmt THEN v_c->0->>'ser' END,
                'creditor_id', CASE WHEN v_stmt AND v_mand IS NOT NULL THEN (SELECT max(x->>'cid') FROM jsonb_array_elements(v_c) x) END,
                'mandate_ref', CASE WHEN v_stmt AND v_mand IS NOT NULL THEN (SELECT max(x->>'mref') FROM jsonb_array_elements(v_c) x) END,
                '_me', finance.fn_monthly_equivalent(v_amt, v_int, v_unit)))
                || jsonb_build_object('schedule_day_of_month', v_dom));
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'suggestions', COALESCE((SELECT jsonb_agg(s - '_me' ORDER BY (s->>'_me')::numeric DESC, s->>'name')
                                 FROM jsonb_array_elements(v_sugs) s), '[]'::jsonb),
        'known_elsewhere', v_elsewh,
        'hints', v_hints);
END;
$$;
