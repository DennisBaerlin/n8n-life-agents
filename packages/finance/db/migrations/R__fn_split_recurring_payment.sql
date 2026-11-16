-- ============================================================
-- fn_split_recurring_payment (INTERNAL HELPER — not tool-facing)
--   Der eine history-erhaltende Validity-Split einer recurring_payment. Gerufen von
--   fn_set_recurring_payment und fn_set_savings_plan.
--   Alte Zeile endet zum Stichtag (valid_to = p_eff_from, exklusiv); neue Zeile gilt ab p_eff_from und erbt
--   von der alten: account_id, target_account_id (Transfer bleibt Transfer), status (pausiert bleibt
--   pausiert), das bisherige Ende (wenn kein neues), den Rhythmus-Anker first_payment_date (bei gleicher
--   Kadenz; sonst Neu-Anker am Stichtag). Vorkommen vor valid_from blendet fn_recurring_due_open aus ->
--   am Stichtag ist nie alte und neue Rate faellig.
--   Positionale Args (fn-intern): p_amount signed (NULL = alter Betrag), p_interval/p_unit/p_dom/p_name/p_notes
--   (NULL = alter Wert), p_valid_to = neues Ende exklusiv gespeichert (Aufrufer rechnet die inklusive
--   Nutzer-Eingabe +1 Tag um; NULL = altes Ende).
--   Vorgaenger-Kette: die neue Zeile traegt predecessor_id = alte Zeile; alle Besitzer
--   (Kredit/Sparplan/Sparziel/Versicherung/Vorsorge) zeigen danach auf die neue Zeile (fn_repoint_recurring_owners,
--   Kopf-Regel). Alte Vorkommen vor dem Stichtag bleiben auf der alten Zeile und werden ueber
--   fn_recurring_lineage weiter ihrem Besitzer zugeordnet.
--   Korrigierbar (kein Write) -> {ok:false, reason, ...}: Stichtag nicht nach valid_from (current_valid_from); alte Zeile
--   vor dem Stichtag schon beendet (last_valid_day); Stichtag nicht nach der letzten gebuchten/uebersprungenen Rate
--   (last_booked; sonst gaelten Vorkommen doppelt; "gebucht" keyt auf die Faelligkeit recurring_due_date, nicht aufs
--   Buchungsdatum); neues Ende nicht nach dem Stichtag. RAISE nur bei unbekannter p_rp_id.
--   executed_by (Nutzerangabe: Dauerauftrag bei der Bank oder selbst ueberwiesen, NULL = nicht angegeben) erbt die neue Zeile.
--   Feste Monatstage p_days (optional, letzter Parameter): NULL = von der alten Zeile erben, solange die Einheit
--   'month' bleibt und kein neuer Einzeltag p_dom kommt; '{}' = leeren; sonst die neuen Tage (der Einzeltag wird
--   dann NULL, CHECK finance_rp_schedule_days_chk). Andere Tage = Kadenzwechsel -> Neu-Anker am Stichtag.
--   Neuer Buchungstag p_dom (Monats-Rhythmus): Stichtag und Ende kommen aus fn_recurring_day_shift ab p_eff_from (jeder Monat
--   behaelt genau einen Termin), ein neues Ende p_valid_to gilt woertlich.
--   RUECKGABE: {ok:true, recurring_payment_id} (neue Zeile).
-- ============================================================

-- ============================================================
-- fn_recurring_day_shift (READ HELPER, STABLE) -- Grenzen einer reinen Buchungstag-Verschiebung
--   Der Termin jedes Monats wandert auf den neuen Tag p_dom, keiner faellt weg, keiner kommt dazu. Nur Monats-Rhythmus ohne feste
--   Monatstage und mit geaendertem Tag (gespeichert NULL = Tag des Ankers); sonst keine Zeile (Aufrufer bleibt beim alten Weg).
--   n_old = erster alter Termin >= p_from (und >= valid_from/Anker, < valid_to); n_new = neuer Tag im selben Monat.
--   start_date = LEAST(n_old, n_new): der eine Tag, an dem die alten Termine enden und die neuen beginnen koennen (der Vormonat
--   liegt auf beiden Tagen davor). new_anchor = n_new (Rhythmus-Anker der Zeile mit dem neuen Tag; liegt im Raster der Kadenz).
--   valid_to (exklusiv): letzter alter Termin e_old vor dem Ende -> neuer Tag im selben Monat e_new; e_new + 1, wenn e_new sonst
--   hinter dem Ende laege oder der naechste neue Termin noch davor (Rate fiele weg / kaeme dazu); sonst das alte Ende. NULL = offen.
--   Ein Glied mit Nachfolger behaelt sein Ende (die Grenze gehoert der Kette).
--   Eingabe: p_rp_id, p_from, p_dom. Rueckgabe: TABLE(start_date, new_anchor, valid_to); keine Zeile ohne Verschiebung oder Termin.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_day_shift(p_rp_id int, p_from date, p_dom smallint)
RETURNS TABLE(start_date date, new_anchor date, valid_to date) LANGUAGE sql STABLE AS $$
    WITH r AS (
        SELECT rp.*, GREATEST(COALESCE(p_from, rp.valid_from), rp.valid_from) AS s,
               GREATEST(COALESCE(rp.schedule_interval, 1), 1) AS n,
               EXISTS (SELECT 1 FROM finance.recurring_payments sx WHERE sx.predecessor_id = rp.id) AS has_successor
        FROM finance.recurring_payments rp
        WHERE rp.id = p_rp_id AND rp.schedule_unit = 'month' AND rp.schedule_days_of_month IS NULL
          AND p_dom IS NOT NULL
          AND p_dom IS DISTINCT FROM COALESCE(rp.schedule_day_of_month, extract(day FROM rp.first_payment_date)::smallint)
    ), o AS (
        SELECT r.*,
               (SELECT min(x.d) FROM finance.fn_schedule_occurrences(r.first_payment_date, r.n, 'month',
                    r.schedule_day_of_month, NULL, r.s,
                    LEAST(COALESCE(r.valid_to - 1, 'infinity'::date), GREATEST(r.s, r.first_payment_date) + (r.n * 31 + 31))) x(d)) AS n_old,
               (SELECT max(x.d) FROM finance.fn_schedule_occurrences(r.first_payment_date, r.n, 'month',
                    r.schedule_day_of_month, NULL, r.s, r.valid_to - 1) x(d)) AS e_old
        FROM r
    ), m AS (
        SELECT o.*,
               finance.fn_schedule_first_occurrence(date_trunc('month', o.n_old)::date, 1, 'month', p_dom, NULL) AS n_new,
               finance.fn_schedule_first_occurrence(date_trunc('month', o.e_old)::date, 1, 'month', p_dom, NULL) AS e_new,
               finance.fn_schedule_first_occurrence((date_trunc('month', o.e_old) + make_interval(months => o.n))::date,
                                                    1, 'month', p_dom, NULL) AS e_next
        FROM o WHERE o.n_old IS NOT NULL
    )
    SELECT LEAST(m.n_old, m.n_new), m.n_new,
           CASE WHEN m.valid_to IS NULL OR m.e_old IS NULL OR m.has_successor THEN m.valid_to
                WHEN m.e_new >= m.valid_to OR m.e_next < m.valid_to THEN m.e_new + 1
                ELSE m.valid_to END
    FROM m;
$$;

-- ============================================================
-- fn_recurring_first_due (READ HELPER, STABLE) -- erster noch nicht erledigter Termin einer Zeile
--   Erster Rasterpunkt dieser Zeile (nicht des Ketten-Kopfs, anders als fn_recurring_next_due) mit
--   d >= max(valid_from, juengster erledigter Termin der Kette + 1) und d < valid_to; ohne Heute-Grenze (ein ueberfaelliger
--   offener Termin ist der erste). Post-State der Aenderungs-fns: ab welchem Termin die neuen Bedingungen gelten.
--   Eingabe: p_rp_id. Rueckgabe: date; NULL bei nicht aktiver Zeile (pausiert: nichts faellig) oder wenn im Suchfenster
--   (zwei Perioden + ein Monat) kein Termin liegt.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_first_due(p_rp_id int)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT min(o.d)
    FROM finance.recurring_payments r
    CROSS JOIN LATERAL (SELECT GREATEST(r.valid_from, r.first_payment_date,
                                        finance.fn_recurring_last_done(r.id) + 1) AS s) f
    CROSS JOIN LATERAL finance.fn_schedule_occurrences(
        r.first_payment_date, r.schedule_interval, r.schedule_unit, r.schedule_day_of_month, r.schedule_days_of_month,
        f.s, f.s + (ceil(finance.fn_period_months(r.schedule_interval, r.schedule_unit) * 2 * 31)::int + 31)) AS o(d)
    WHERE r.id = p_rp_id AND r.status = 'active'
      AND (r.valid_to IS NULL OR o.d < r.valid_to);
$$;

-- ============================================================
-- fn_recurring_reanchor_day (INTERNAL HELPER, WRITE) -- Buchungstag in place, solange noch nichts erledigt/faellig war
--   Fuer fn_set_recurring_payment und fn_change_owned_recurring (In-place-Zweig): setzt first_payment_date = new_anchor und
--   valid_from = LEAST(valid_from, start_date) aus fn_recurring_day_shift, Ende abgebildet. Untergrenzen des Starts:
--   Eroeffnungssaldo beider Konten (ein Termin davor steckt schon im Saldo, fn_recurring_valid_from) und der letzte Termin eines
--   Vorgaenger-Glieds; dessen Ende folgt einem frueheren Start (Kette ohne Ueberlappung). schedule_day_of_month setzt der Aufrufer.
--   Eingabe: p_rp_id, p_dom. Rueckgabe: true, wenn verschoben (sonst nichts geschrieben).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_reanchor_day(p_rp_id int, p_dom smallint)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
    v_row   finance.recurring_payments%ROWTYPE;
    v_shift RECORD;
    v_vf    DATE;
BEGIN
    SELECT * INTO v_row FROM finance.recurring_payments WHERE id = p_rp_id FOR UPDATE;
    SELECT * INTO v_shift FROM finance.fn_recurring_day_shift(p_rp_id, v_row.valid_from, p_dom);
    IF v_shift.start_date IS NULL THEN
        RETURN false;
    END IF;
    v_vf := LEAST(v_row.valid_from, v_shift.start_date);
    v_vf := GREATEST(finance.fn_recurring_valid_from(v_row.account_id, v_vf),
                     finance.fn_recurring_valid_from(v_row.target_account_id, v_vf));   -- NULL-Konto -> v_vf
    SELECT GREATEST(v_vf, max(o.d) + 1) INTO v_vf   -- Aggregat: auch ohne Vorgaenger genau eine Zeile, GREATEST ignoriert NULL
    FROM finance.recurring_payments pr
    CROSS JOIN LATERAL finance.fn_schedule_occurrences(pr.first_payment_date, pr.schedule_interval, pr.schedule_unit,
        pr.schedule_day_of_month, pr.schedule_days_of_month, pr.valid_from, pr.valid_to - 1) o(d)
    WHERE pr.id = v_row.predecessor_id;
    UPDATE finance.recurring_payments SET valid_to = v_vf
     WHERE id = v_row.predecessor_id AND valid_to = v_row.valid_from AND v_vf < v_row.valid_from;
    UPDATE finance.recurring_payments
       SET valid_from = v_vf, first_payment_date = v_shift.new_anchor, valid_to = v_shift.valid_to
     WHERE id = p_rp_id;
    RETURN true;
END;
$$;

DROP FUNCTION IF EXISTS finance.fn_split_recurring_payment(int, date, numeric, smallint, finance.schedule_unit, smallint, text, text, date);
CREATE OR REPLACE FUNCTION finance.fn_split_recurring_payment(
    p_rp_id     int,
    p_eff_from  date,
    p_amount    numeric,
    p_interval  smallint,
    p_unit      finance.schedule_unit,
    p_dom       smallint,
    p_name      text,
    p_notes     text,
    p_valid_to  date,
    p_days      smallint[] DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_old      finance.recurring_payments%ROWTYPE;
    v_last     DATE;
    v_interval SMALLINT;
    v_unit     finance.schedule_unit;
    v_days     SMALLINT[];
    v_dom      SMALLINT;
    v_new_id   INT;
    v_shift    RECORD;
    v_anchor   DATE;      -- Anker der neuen Zeile bei reiner Tag-Verschiebung (fn_recurring_day_shift)
BEGIN
    SELECT * INTO v_old FROM finance.recurring_payments WHERE id = p_rp_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', p_rp_id;
    END IF;
    -- Neuer Buchungstag ohne Kadenzwechsel: Stichtag/Ende so, dass jeder Monat genau einen Termin behaelt (vor den Guards)
    -- Nicht bei p_days ('{}' inklusive): fn_set_savings_plan nennt mit dem Depot-Kalender die erste Ausfuehrung selbst als
    -- Stichtag, die Karte zeigt sie (test_fn_set_savings_plan_day_shift)
    IF p_days IS NULL
       AND (p_unit IS NULL OR p_unit = v_old.schedule_unit)
       AND (p_interval IS NULL OR p_interval = v_old.schedule_interval) THEN
        SELECT * INTO v_shift FROM finance.fn_recurring_day_shift(p_rp_id, p_eff_from, p_dom);
        IF v_shift.start_date IS NOT NULL THEN
            -- Der neue Tag laege im ersten Monat vor dem Beginn dieser Zeile: dann gibt es noch keinen alten Termin zu
            -- trennen -> erst den Tag allein (in place), dann den Rest
            IF v_shift.start_date <= v_old.valid_from THEN
                RETURN jsonb_build_object('ok', false, 'code', 'day_before_start',
                    'reason', 'With the new debit day the first payment would be on ' || v_shift.new_anchor
                           || ', before this entry starts (' || v_old.valid_from || '). Change the debit day alone first, '
                           || 'then the other terms.',
                    'current_valid_from', v_old.valid_from);
            END IF;
            p_eff_from := v_shift.start_date;
            p_valid_to := COALESCE(p_valid_to, v_shift.valid_to);
            v_anchor   := v_shift.new_anchor;
        END IF;
    END IF;

    IF p_eff_from <= v_old.valid_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Effective date (' || p_eff_from || ') must be after the current entry valid_from (' || v_old.valid_from || ').',
            'current_valid_from', v_old.valid_from);
    END IF;
    IF v_old.valid_to IS NOT NULL AND v_old.valid_to <= p_eff_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This payment already ended (last valid day ' || (v_old.valid_to - 1)
                   || ') before the effective date ' || p_eff_from || '; create a new payment instead.',
            'last_valid_day', v_old.valid_to - 1);
    END IF;

    SELECT max(d) INTO v_last FROM (
        SELECT max(recurring_due_date) AS d FROM finance.transactions WHERE recurring_payment_id = p_rp_id
        UNION ALL
        SELECT max(due_date) FROM finance.recurring_payment_skips WHERE recurring_payment_id = p_rp_id
    ) x;
    IF v_last IS NOT NULL AND p_eff_from <= v_last THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The payment due on ' || v_last || ' is already booked or skipped at the old terms; '
                   || 'choose an effective date after ' || v_last || '.',
            'last_booked', v_last);
    END IF;

    IF p_valid_to IS NOT NULL AND p_valid_to <= p_eff_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The end date (last valid day ' || (p_valid_to - 1) || ') must not be before the effective date '
                   || p_eff_from || '.');
    END IF;

    v_interval := COALESCE(p_interval, v_old.schedule_interval);
    v_unit     := COALESCE(p_unit, v_old.schedule_unit);
    -- Feste Monatstage: neue Liste > geerbte (nur bei month ohne neuen Einzeltag) ; Tage und Einzeltag schliessen sich aus
    v_days := CASE WHEN v_unit <> 'month' THEN NULL
                   WHEN p_days IS NOT NULL THEN NULLIF(p_days, '{}')
                   WHEN p_dom IS NOT NULL THEN NULL
                   ELSE v_old.schedule_days_of_month END;
    v_dom  := CASE WHEN v_days IS NOT NULL THEN NULL ELSE COALESCE(p_dom, v_old.schedule_day_of_month) END;

    UPDATE finance.recurring_payments SET valid_to = p_eff_from WHERE id = p_rp_id;

    v_new_id := finance.fn_add_recurring_payment(
        v_old.account_id,
        COALESCE(p_amount, v_old.amount),
        COALESCE(NULLIF(p_name, ''), v_old.name),
        v_interval,
        v_unit,
        v_dom,
        CASE WHEN v_interval = v_old.schedule_interval AND v_unit = v_old.schedule_unit
                  AND v_days IS NOT DISTINCT FROM v_old.schedule_days_of_month
             THEN COALESCE(v_anchor, v_old.first_payment_date) ELSE p_eff_from END,
        p_eff_from,
        COALESCE(p_valid_to, v_old.valid_to),
        v_old.status,
        COALESCE(NULLIF(p_notes, ''), v_old.notes));

    -- Transfer bleibt Transfer + Vorgaenger-Link + feste Monatstage (fn_add_recurring_payment-Signatur bewusst
    -- unveraendert; No-Self-Transfer- und Tage-CHECK sind zeilenweise und durch die geerbten Werte erfuellt).
    UPDATE finance.recurring_payments
    SET target_account_id = v_old.target_account_id, predecessor_id = p_rp_id, schedule_days_of_month = v_days,
        executed_by = v_old.executed_by   -- Nutzerangabe zum Uebertrag erben (CHECK: nur mit Ziel-Konto, oben mitgesetzt)
    WHERE id = v_new_id;
    PERFORM finance.fn_repoint_recurring_owners(p_rp_id, v_new_id);

    RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_new_id);
END;
$$;
