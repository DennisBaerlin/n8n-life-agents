-- ============================================================
-- fn_get_recurring_suggestions (READ, STABLE) -- wiederkehrende Zahlungen aus einem Bank-Export erkennen ("Import zuerst")
--   Die Datei kommt ueber fn_bank_export_load (Leser + Konto-Waechter + Sub-Konto-Waechter; kein Startpunkt noetig, es
--   wird nichts gebucht). Rechnet alles in der DB (das LLM uebernimmt die Werte nur in die Write-Tools,
--   tool_create_recurring_payment / tool_create_recurring_transfer mit Karte). Muster: Actual "Find schedules",
--   Plaid /transactions/recurring/get, Sure RecurringTransaction::Identifier (Belege im Plan der Session 3d).
--   1. Zeilen: kind cash, Betrag <> 0 (Zins, Wertpapier, Bondora-Altkredit-Rueckfluesse nie).
--   2. Schluessel je Vorzeichen: Gegenkonto (Gegen-IBAN = Kontonummer eines anderen aktiven eigenen Kontos bzw.
--      Bondora-Ein-/Auszahlung -> Verrechnungskonto), sonst Gegen-IBAN (nur echte, fn_iban_strict), sonst Name (die
--      ersten zwei Woerter ohne Ziffern, klein: Karten-Fragmente wie "SHOP 4711" bleiben eine Reihe). Name im Vorschlag =
--      Gegenpart wie gedruckt, ohne Gegenpart die ersten drei Woerter ohne Ziffern des Buchungstexts (nie der ganze
--      Verwendungszweck).
--   3. Betrag: Ausgaben in Clustern +-7,5 % um den laufenden Mittelwert (Actual/Sure); zeitlich aufeinander folgende
--      Cluster (je >= 2 Zeilen) eines Schluessels = Preisstufe -> eine Reihe. Einnahmen ohne Betrags-Cluster (Gehalt).
--      Mehrere Reihen auf einer IBAN (Zahlungsdienst) -> die IBAN ist kein Schluessel (kein counterparty_iban, (a) eng).
--      Mehrere Zeilen am selben Tag in einer Reihe = ein Termin mit der Summe.
--   4. Rhythmus aus dem Median-Abstand: week 1/2, month 1/3/6, year 1. Jede Zeile zaehlt zum NAECHSTEN Faelligkeitstag
--      des Rasters (month: Tag 1-28 oder -1 = Monatsletzter, gewaehlt nach den meisten Treffern, dann der kleinsten
--      Abweichung; Phase des Intervalls aus der juengsten Zeile). Treffer = +-3 Tage (week +-2; Wochenende + Feiertag
--      verschieben Buchungstage), Reihe gilt bei >= 80 % Treffern (Sonderzahlung = Ausreisser). Reif: >= 3 Termine
--      (month 3/6, year: >= 2); aktiv: letzter Termin hoechstens 1,5 Intervalle vor dem Dateiende.
--   5. Startdatum first_payment_date = naechster Rastertermin nach dem letzten getroffenen Termin UND nach
--      last_reconciled_at des Kontos (kein schon bezahltes/abgeglichenes Vorkommen bleibt offen).
--   6. Bekannt-Filter gegen jede laufende Zeile (active_recurring_payments) bzw. erst kuenftig startende (sonst kaeme ein
--      eben angelegter Vorschlag gleich wieder) dieses Kontos als Quelle/Ziel, auch Versicherung/Kredit/Sparziel/Vorsorge:
--      (a) IBAN-Schluessel der Kette + Betrag 50-150 % (geteilte IBAN: +-7,5 %), (b) Transfer mit demselben Gegenkonto +
--      Betrag 50-150 %, (c) exakter Betrag im gleichen Rhythmus am gleichen Tag (+-3) ohne fremden IBAN-Schluessel,
--      (d) Namens-Wort (>= 4 Zeichen, Trennzeichen wie Stufe B) + Betrag +-7,5 %. (a)/(d) auf einem anderen Konto ->
--      known_elsewhere statt Vorschlag.
--   7. Art: transfer (Gegenkonto), household (fn_match_household_holder: Haushaltsmitglied ohne eigenes Konto mit der
--      IBAN -> der Agent fragt, welches Konto), sonst payment (direction income|expense).
--   Spanne erste-letzte Buchung < 75 Tage (~3 Monate) -> keine Vorschlaege, hint export_too_short (Plaid empfiehlt 180
--   Tage); Dateiende aelter als 45 Tage -> hint export_stale.
--   plpgsql (late-bound): fn_iban_strict, fn_match_household_holder, fn_monthly_equivalent liegen spaeter bzw. im Init.
--   Eingabe jsonb: {account_name (optional), table:{rows}}. Fehlertexte nennen nie Zellinhalte.
--   RUECKGABE: {ok:true, account_name, period_first, period_last, span_days, hint?, suggestions:[{name (Schreibweise
--   der juengsten Zeile), kind, direction, counterparty_iban?, from_account?, to_account?, amount (juengster Betrag,
--   positiv), average_amount, amount_varies, schedule_unit, schedule_interval, schedule_day_of_month (NULL ausser
--   month), first_payment_date, occurrences, first_date, last_date}] (nach Monatsbetrag absteigend),
--   known_elsewhere:[{name, account_name}]} | Codes von fn_bank_export_load.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_recurring_suggestions(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_today          DATE := core.fn_today();
    v_load     JSONB;
    v_acct     finance.accounts%ROWTYPE;
    v_first    DATE;
    v_last     DATE;
    v_hint     TEXT;
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
    v_txt      TEXT;
    v_iban     TEXT;
    v_other    INT;
    v_sign     INT;
    v_kind     TEXT;
    v_else     TEXT;
    v_sugs     JSONB := '[]'::jsonb;
    v_elsewh   JSONB := '[]'::jsonb;
    v_shared   BOOLEAN;
BEGIN
    v_load := finance.fn_bank_export_load(p);
    IF (v_load->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_load;
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = (v_load->>'account_id')::int;
    SELECT min((r->>'date')::date), max((r->>'date')::date) INTO v_first, v_last
    FROM jsonb_array_elements(v_load->'rows') r;
    -- Spanne zwischen erster und letzter Buchung: ein echter 3-Monats-Export (1.8.-31.10.) hat Buchungen ab ~3.8. bis
    -- ~28.10. = 86 Tage -> Schwelle 75 Tage (Review 2026-10-30), sonst fordert der Agent im Kreis "mindestens 3 Monate"
    IF v_first IS NULL OR v_last - v_first < 75 THEN
        RETURN jsonb_build_object('ok', true, 'account_name', v_acct.name, 'period_first', v_first, 'period_last', v_last,
            'span_days', COALESCE(v_last - v_first, 0), 'hint', 'export_too_short',
            'reason', 'The export covers less than 3 months - ask for an export of the last 6 months (at least 3).',
            'suggestions', '[]'::jsonb, 'known_elsewhere', '[]'::jsonb);
    END IF;
    IF v_last < v_today - 45 THEN
        v_hint := 'export_stale';
    END IF;

    -- ---------- 1./2. Zeilen + Schluessel ----------
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
            -- Name: der Gegenpart wie gedruckt; ohne Gegenpart (Karte bei Trade Republic) die ersten drei Woerter ohne
            -- Ziffern des Buchungstexts - nie der ganze Verwendungszweck (Kunden-/Vertragsnummern gehen nicht ans Modell)
            SELECT (r->>'date')::date AS d, round((r->>'cash_amount')::numeric, 2) AS amt, r->>'sub_kind' AS sub_kind,
                   COALESCE(NULLIF(btrim(r->>'counterparty'), ''),
                            (SELECT string_agg(w, ' ' ORDER BY o) FROM (
                                 SELECT w, o FROM regexp_split_to_table(btrim(COALESCE(NULLIF(btrim(r->>'purpose'), ''), r->>'name', '')), '\s+')
                                        WITH ORDINALITY s(w, o)
                                 WHERE w <> '' AND w !~ '[0-9]' ORDER BY o LIMIT 3) z)) AS nm,
                   CASE WHEN finance.fn_iban_strict(r->>'counterparty_iban')
                        THEN finance.fn_normalize_account_number(r->>'counterparty_iban') END AS iban
            FROM jsonb_array_elements(v_load->'rows') r
            WHERE r->>'kind' = 'cash' AND COALESCE((r->>'cash_amount')::numeric, 0) <> 0
              AND COALESCE(r->>'sub_kind', '') <> 'legacy_return'
        ) y
    ) x
    WHERE x.other IS NOT NULL OR x.iban IS NOT NULL OR x.nkey IS NOT NULL;

    FOR v_g IN
        SELECT l->>'gk' AS gk, sign((l->>'amt')::numeric)::int AS sg,
               jsonb_agg(l ORDER BY abs((l->>'amt')::numeric), (l->>'d')::date) AS items
        FROM jsonb_array_elements(v_lines) l
        GROUP BY 1, 2
        HAVING count(*) >= 2
    LOOP
        -- ---------- 3. Betrags-Cluster ----------
        IF v_g.sg > 0 THEN
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
            -- Preisstufe: zeitlich ueberschneidungsfreie Cluster (je >= 2 Zeilen) desselben Schluessels = eine Reihe
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

        -- Mehrere Reihen auf EINER Gegen-IBAN (Zahlungsdienst wie PayPal/Klarna: viele Haendler, eine IBAN) -> die IBAN
        -- taugt nicht als Schluessel: kein counterparty_iban im Vorschlag, Bekannt-Filter (a) nur mit +-7,5 %
        v_shared := (SELECT count(*) FROM jsonb_array_elements(v_merged) c WHERE jsonb_array_length(c) >= 2) > 1;

        FOR v_c IN SELECT c FROM jsonb_array_elements(v_merged) c WHERE jsonb_array_length(c) >= 2 LOOP
            -- Zwei Zahlungen am selben Tag an denselben Schluessel (zwei Kita-Beitraege, Gehalt + Zulage) = EIN Termin
            -- mit der Summe (sonst Abstand 0 im Median und ein zufaelliger Einzelbetrag)
            v_c := (SELECT jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'iban', x.iban, 'other', x.other) ORDER BY x.d)
                    FROM (SELECT (e->>'d')::date AS d, sum((e->>'amt')::numeric) AS amt, min(e->>'nm') AS nm,
                                 min(e->>'iban') AS iban, min(e->>'other') AS other
                          FROM jsonb_array_elements(v_c) e GROUP BY 1) x);
            CONTINUE WHEN jsonb_array_length(v_c) < 2;
            -- ---------- 4. Rhythmus ----------
            v_ds := ARRAY(SELECT (x->>'d')::date FROM jsonb_array_elements(v_c) x ORDER BY 1);
            v_n := cardinality(v_ds);
            v_lastd := v_ds[v_n];
            SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v_ds[i + 1] - v_ds[i]) INTO v_gap
            FROM generate_series(1, v_n - 1) i;
            v_unit := NULL; v_tol := 3; v_dom := NULL;
            IF v_gap BETWEEN 5 AND 9 THEN v_unit := 'week'; v_int := 1; v_tol := 2;
            ELSIF v_gap BETWEEN 12 AND 16 THEN v_unit := 'week'; v_int := 2; v_tol := 2;
            ELSIF v_gap BETWEEN 25 AND 36 THEN v_unit := 'month'; v_int := 1;
            ELSIF v_gap BETWEEN 80 AND 100 THEN v_unit := 'month'; v_int := 3;
            ELSIF v_gap BETWEEN 170 AND 195 THEN v_unit := 'month'; v_int := 6;
            ELSIF v_gap BETWEEN 350 AND 380 THEN v_unit := 'year'; v_int := 1;
            END IF;
            CONTINUE WHEN v_unit IS NULL;

            IF v_unit = 'month' THEN
                -- Monatstag: die meisten Treffer, dann die kleinste Abweichung (Tage 29/30 landen bei -1 = Monatsletzter,
                -- 1-2 Tage daneben: im Fenster des Monats-Checks ohne Folge)
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
            ELSE
                SELECT jsonb_agg(jsonb_build_object('d', x.d, 'amt', x.amt, 'nm', x.nm, 'due', x.due, 'ok', abs(x.d - x.due) <= v_tol)
                           ORDER BY x.d)
                INTO v_fit
                FROM (SELECT (e->>'d')::date AS d, (e->>'amt')::numeric AS amt, e->>'nm' AS nm,
                             (v_lastd - make_interval(years => round((v_lastd - (e->>'d')::date) / 365.25)::int))::date AS due
                      FROM jsonb_array_elements(v_c) e) x;
            END IF;

            SELECT count(*) FILTER (WHERE (f->>'ok')::boolean),
                   count(DISTINCT (f->>'due')::date) FILTER (WHERE (f->>'ok')::boolean),
                   max((f->>'due')::date) FILTER (WHERE (f->>'ok')::boolean)
            INTO v_fb, v_occ, v_last_due
            FROM jsonb_array_elements(v_fit) f;
            CONTINUE WHEN v_fb < 0.8 * v_n;
            CONTINUE WHEN v_occ < CASE WHEN v_unit = 'year' OR (v_unit = 'month' AND v_int >= 3) THEN 2 ELSE 3 END;
            -- aktiv = gemessen am Dateiende (ein Export, der vor Wochen endete, verliert sonst still seine Monatszahlungen;
            -- ein alter Export traegt hint export_stale)
            CONTINUE WHEN v_last - v_last_due
                          > 1.5 * CASE v_unit WHEN 'week' THEN 7 * v_int WHEN 'month' THEN 30.44 * v_int ELSE 365 END;

            -- ---------- 5. Startdatum: naechster Rastertermin nach dem letzten Termin und nach dem Abgleich ----------
            v_floor := GREATEST(v_last_due, v_acct.last_reconciled_at);
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

            -- Betrag/Name aus den getroffenen Zeilen (juengste zuletzt)
            SELECT abs((f->>'amt')::numeric), f->>'nm' INTO v_amt, v_name
            FROM jsonb_array_elements(v_fit) f WHERE (f->>'ok')::boolean
            ORDER BY (f->>'d')::date DESC LIMIT 1;
            SELECT round(avg(abs((f->>'amt')::numeric)), 2), max(abs((f->>'amt')::numeric)) - min(abs((f->>'amt')::numeric)) > 0.005
            INTO v_avg, v_var
            FROM jsonb_array_elements(v_fit) f WHERE (f->>'ok')::boolean;
            v_sign  := v_g.sg;
            v_iban  := v_c->0->>'iban';
            v_other := (v_c->0->>'other')::int;
            v_txt   := lower(COALESCE(v_name, ''));

            -- ---------- 6. Bekannt-Filter ----------
            -- Kandidaten = was laeuft (Praedikat von finance.active_recurring_payments) ODER erst kuenftig startet (sonst
            -- kaeme ein eben angelegter Vorschlag beim naechsten Aufruf wieder). Namens-Woerter wie fn_statement_match
            -- Stufe B (gleiche Trennzeichen), damit "bekannt" hier und "getroffen" im Monats-Check dasselbe heissen.
            CONTINUE WHEN EXISTS (
                SELECT 1 FROM finance.recurring_payments r
                CROSS JOIN LATERAL (SELECT CASE WHEN r.account_id = v_acct.id THEN r.amount ELSE abs(r.amount) END AS e,
                                           CASE WHEN r.account_id = v_acct.id THEN r.target_account_id ELSE r.account_id END AS o) x
                WHERE (r.id IN (SELECT ar.id FROM finance.active_recurring_payments ar)
                       OR (r.status = 'active' AND r.valid_from > current_date))
                  AND (r.account_id = v_acct.id OR r.target_account_id = v_acct.id)
                  AND sign(x.e) = v_sign
                  -- (a) IBAN-Schluessel der Kette; geteilte IBAN (Zahlungsdienst) nur bei nahezu gleichem Betrag
                  AND ( (v_iban IS NOT NULL AND EXISTS (
                            SELECT 1 FROM finance.recurring_payment_keys k
                            WHERE k.key_type = 'counterparty_iban' AND k.key_value = v_iban
                              AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(r.id)))
                        AND (CASE WHEN v_shared THEN abs(v_amt - abs(x.e)) <= abs(x.e) * 0.075
                                  ELSE v_amt BETWEEN abs(x.e) * 0.5 AND abs(x.e) * 1.5 END))
                     -- (b) Transfer mit demselben Gegenkonto und aehnlichem Betrag
                     OR (v_other IS NOT NULL AND r.target_account_id IS NOT NULL AND x.o = v_other
                         AND v_amt BETWEEN abs(x.e) * 0.5 AND abs(x.e) * 1.5)
                     -- (c) exakter Betrag im gleichen Rhythmus am gleichen Tag (+-3, Kreis-Kalender), und kein
                     --     IBAN-Schluessel der Kette, der einer anderen IBAN gehoert (Versicherung unter eigenem Namen)
                     OR (abs(v_amt - abs(x.e)) <= 0.005 AND r.schedule_unit = v_unit AND r.schedule_interval = v_int
                         AND (r.schedule_day_of_month IS NULL OR v_dom IS NULL
                              OR LEAST(abs(r.schedule_day_of_month - v_dom), 31 - abs(r.schedule_day_of_month - v_dom)) <= v_tol
                              OR (r.schedule_day_of_month = -1 AND v_dom >= 28) OR (v_dom = -1 AND r.schedule_day_of_month >= 28))
                         AND NOT EXISTS (
                            SELECT 1 FROM finance.recurring_payment_keys k
                            WHERE k.key_type = 'counterparty_iban' AND k.key_value IS DISTINCT FROM v_iban
                              AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(r.id))))
                     -- (d) Namens-Wort des Dauerauftrags (>= 4 Zeichen) im Namen + Betrag +-7,5 %
                     OR (abs(v_amt - abs(x.e)) <= abs(x.e) * 0.075 AND EXISTS (
                            SELECT 1 FROM regexp_split_to_table(lower(r.name), '[\s,.;:/()_+&-]+') tok
                            WHERE length(tok) >= 4 AND position(tok IN v_txt) > 0)) ));

            SELECT a.name INTO v_else
            FROM finance.recurring_payments r
            JOIN finance.accounts a ON a.id = r.account_id
            WHERE (r.id IN (SELECT ar.id FROM finance.active_recurring_payments ar)
                   OR (r.status = 'active' AND r.valid_from > current_date))
              AND r.account_id <> v_acct.id AND r.target_account_id IS DISTINCT FROM v_acct.id
              AND ( (v_iban IS NOT NULL AND EXISTS (
                        SELECT 1 FROM finance.recurring_payment_keys k
                        WHERE k.key_type = 'counterparty_iban' AND k.key_value = v_iban
                          AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(r.id)))
                    AND (CASE WHEN v_shared THEN abs(v_amt - abs(r.amount)) <= abs(r.amount) * 0.075
                              ELSE v_amt BETWEEN abs(r.amount) * 0.5 AND abs(r.amount) * 1.5 END))
                 OR (abs(v_amt - abs(r.amount)) <= abs(r.amount) * 0.075 AND EXISTS (
                        SELECT 1 FROM regexp_split_to_table(lower(r.name), '[\s,.;:/()_+&-]+') tok
                        WHERE length(tok) >= 4 AND position(tok IN v_txt) > 0)) )
            ORDER BY r.id LIMIT 1;
            IF v_else IS NOT NULL THEN
                v_elsewh := v_elsewh || jsonb_build_array(jsonb_build_object('name', v_name, 'account_name', v_else));
                CONTINUE;
            END IF;

            -- ---------- 7. Art ----------
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
                'amount', v_amt, 'average_amount', v_avg, 'amount_varies', v_var,
                'schedule_unit', v_unit, 'schedule_interval', v_int, 'first_payment_date', v_next,
                'occurrences', v_occ, 'first_date', v_ds[1], 'last_date', v_lastd,
                '_me', finance.fn_monthly_equivalent(v_amt, v_int, v_unit)))
                || jsonb_build_object('schedule_day_of_month', v_dom));
        END LOOP;
    END LOOP;

    RETURN jsonb_strip_nulls(jsonb_build_object('ok', true, 'account_name', v_acct.name, 'period_first', v_first,
               'period_last', v_last, 'span_days', v_last - v_first, 'hint', v_hint))
        || jsonb_build_object(
               'suggestions', COALESCE((SELECT jsonb_agg(s - '_me' ORDER BY (s->>'_me')::numeric DESC, s->>'name')
                                        FROM jsonb_array_elements(v_sugs) s), '[]'::jsonb),
               'known_elsewhere', v_elsewh);
END;
$$;
