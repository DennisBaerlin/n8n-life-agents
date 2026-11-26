-- ============================================================
-- fn_set_recurring_payment (ATOMIC WRITE) -- nur Standalone-Zeilen
--   Aendert eine standalone wiederkehrende Einnahme/Ausgabe (Gehalt/Miete/Abo/Rente).
--   Standalone-Guard: ist die Zeile (bzw. der Kopf ihrer Kette) von einer Entitaet besessen (insurance/loan/
--   savings_goal/pension/savings_plan -> recurring_payment_id, fn_recurring_owner), wird abgelehnt ({ok:false}) -> Aenderung
--   ueber das jeweilige set_<entity>-Tool (sonst Verwaisen der FK beim Split).
--   Betrags-Aenderung = history-erhaltender Validity-Split ("effective date") ueber den
--   gemeinsamen Helfer fn_split_recurring_payment (Vorzeichen aus der alten Zeile; Ziel-Konto, Status, Ende,
--   Rhythmus-Anker geerbt; Guards s. dort). Sonst (kein amount) in place: status (pause/resume),
--   valid_to (beenden), name, schedule_day_of_month, notes.
--   Neuer Buchungstag (Monats-Rhythmus): jeder Monat behaelt genau einen Termin (fn_recurring_day_shift). Ohne erledigte Termine
--   dieser Zeile Neu-Anker in place (first_payment_date = neuer Tag im Startmonat, valid_from zieht bei frueherem Tag mit, Untergrenze
--   Eroeffnungssaldo beider Konten und letzter Termin eines Vorgaengers, dessen Ende folgt; ein Ende wird so verschoben, dass der
--   letzte Termin bleibt). Mit erledigten Terminen Split ab dem Tag nach dem letzten (split=true, previous_id).
--   valid_to-Eingabe ist inklusiv (letzter gueltiger Tag, wie der Nutzer es sagt); gespeichert wird
--   exklusiv (+1 Tag, Konvention [valid_from, valid_to)). Das LLM rechnet nicht.
--   Eingabe jsonb: recurring_payment_id (im n8n aufgeloest), amount (positiver Betrag -> Split),
--   valid_from (Stichtag des Splits; default heute), status, valid_to, schedule_day_of_month,
--   name, notes, chat_id (opt, fuer den Cashflow-Hinweis), until_free_money (true: das Ende setzt die DB,
--   fn_transfer_free_end; nur freistehende Uebertraege, nicht zusammen mit amount oder valid_to; Ablehnung rollt das
--   Update per Savepoint zurueck, SQLSTATE LA002).
--   executed_by (opt, bank|manual): Nutzerangabe zu einem Uebertrag (Dauerauftrag bei der Bank oder der Nutzer ueberweist
--   selbst; leer = unveraendert). Wird auf alle noch laufenden Glieder der Kette geschrieben (Berater-Alarm liest den Kopf,
--   die Uebersicht das gueltige Glied: beide muessen dasselbe zeigen) und mit amount zusaetzlich auf die neue Split-Zeile;
--   nur an Uebertraegen (Zeile mit Ziel-Konto), sonst {ok:false}. Steuert nur Hinweise, nie die Buchung.
--   RUECKGABE: {ok:true, recurring_payment_id, split}; bei split=true zusaetzlich previous_id; mit amount oder einem
--   wirklich neuen Tag first_due (erster noch offener Termin mit den neuen Bedingungen, fn_recurring_first_due; eigenes Feld wie
--   execution, Karte und Antwort lesen es); bei einem Uebertrag zusaetzlich
--   execution (aufgeloest bank|manual|unknown, fn_transfer_executed_by; eigenes Feld, nicht unter effective: das Gate mischt
--   effective in den echten Write); effective (aufgeloeste relative Daten, bei until_free_money zusaetzlich das
--   berechnete Ende aus fn_transfer_free_end); die Keys von fn_cashflow_coverage_fold; card_lines = Bank-Hinweis (fn_bank_setup_note: pausieren/valid_to -> bank_stop,
--   amount/schedule_day_of_month/Fortsetzen -> bank_change; nicht bei until_free_money, Name/Notiz, executed_by manual).
--   Korrigierbar (nicht aufloesbares Datum -> code invalid_date, entitaets-besessen, amount<=0, ungueltiger executed_by
--   oder an einem Nicht-Uebertrag, until_free_money zusammen mit amount/valid_to, Ablehnung von fn_transfer_free_end,
--   Split-Guards des Helfers inkl. last_booked und day_before_start, neuer Tag an einem Glied mit Nachfolger: code has_successor)
--   -> {ok:false}.
--   handoff_task_id (optional): Eintrag einer vereinbarten Plan-Aufgabe -> finance.fn_with_handoff (Pruefung, Abschluss
--   im selben Write, Kartenzeile core.hitl.handoff_note).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_recurring_payment(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id       INT      := (p->>'recurring_payment_id')::int;
    v_amount   NUMERIC  := NULLIF(p->>'amount', '')::numeric;   -- positiver Magnitude-Betrag
    v_from     DATE;                                         -- Stichtag fuer den Split
    v_status   finance.payment_status := NULLIF(p->>'status', '')::finance.payment_status;
    v_to       DATE;                                         -- inklusive Eingabe -> exklusiv gespeichert
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_row      finance.recurring_payments%ROWTYPE;
    v_owner    TEXT;
    v_signed   NUMERIC;
    v_new_id   INT;
    v_eff_from DATE;
    v_core     JSONB;     -- Erfolgs-Kern beider Zweige (Split/In-Place) vor dem Cashflow-Fold
    v_dates    JSONB;
    v_free     BOOLEAN := COALESCE(NULLIF(p->>'until_free_money', '')::boolean, false);
    v_end      JSONB   := '{}'::jsonb;
    v_exec     TEXT    := NULLIF(p->>'executed_by', '');
    v_shift    RECORD;
    v_done     DATE;
    v_vf       DATE;
    v_prev_id  INT;
    v_day_moves BOOLEAN;
BEGIN
    -- Vereinbarte Plan-Aufgabe (Uebergabe Berater -> Buchhalter): pruefen, schreiben, abschliessen in einer Transaktion
    IF NULLIF(btrim(COALESCE(p->>'handoff_task_id', '')), '') IS NOT NULL THEN
        RETURN finance.fn_with_handoff('finance.fn_set_recurring_payment(jsonb)'::regprocedure, p);
    END IF;
    -- relative Datumsangaben ("in 1 month") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['valid_from', 'valid_to']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_from := NULLIF(p->>'valid_from', '')::date;
    v_to   := NULLIF(p->>'valid_to', '')::date + 1;
    -- fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    SELECT * INTO v_row FROM finance.recurring_payments WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', v_id;
    END IF;

    -- Standalone-Guard: entitaets-besessene Zeilen -> ueber das set_<entity>-Tool. Die eine Besitzer-Abfrage
    -- fn_recurring_owner erkennt auch Vorgaenger-Glieder einer Entitaets-Kette (Kopf-Regel).
    v_owner := replace(finance.fn_recurring_owner(v_id), '_', ' ');
    IF v_owner IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This recurring payment belongs to a ' || v_owner || '; change it via that entity set tool, not directly.');
    END IF;
    IF v_exec IS NOT NULL AND v_exec NOT IN ('bank', 'manual') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'executed_by must be "bank" (standing order at the bank) or "manual" (the user transfers it themselves), got "' || v_exec || '". Leave it empty when the user did not say.');
    END IF;
    IF v_exec IS NOT NULL AND v_row.target_account_id IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'executed_by only applies to a transfer between own accounts; this payment goes to an outside party.');
    END IF;
    IF v_free AND (v_amount IS NOT NULL OR v_to IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', '"Until the free money is used up" sets the end itself - change the amount or name an end date in a separate step.');
    END IF;

    -- Neuer Buchungstag (Monats-Rhythmus, anderer Tag)? Ein Glied mit Nachfolger (geplante Aenderung schon angelegt) lehnt
    -- beide Zweige ab: der Tag gehoert der ganzen Kette, ein Split am mittleren Glied gabelte sie
    SELECT * INTO v_shift FROM finance.fn_recurring_day_shift(v_id, v_row.valid_from, v_dom);
    v_day_moves := v_shift.start_date IS NOT NULL;
    IF v_day_moves THEN
        SELECT s.valid_from INTO v_vf FROM finance.recurring_payments s WHERE s.predecessor_id = v_id ORDER BY s.valid_from LIMIT 1;
        IF FOUND THEN
            RETURN jsonb_build_object('ok', false, 'code', 'has_successor',
                'reason', 'This entry is followed by a planned change from ' || v_vf || '. Change the debit day on that later '
                       || 'entry (it is the current terms from then on), or first remove the planned change.',
                'successor_valid_from', v_vf);
        END IF;
    END IF;

    IF v_amount IS NOT NULL THEN
        IF v_amount <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'Amount must be a positive number, got ' || v_amount || '.');
        END IF;
        v_eff_from := COALESCE(v_from, CURRENT_DATE);
        -- Vorzeichen aus der bestehenden Zeile uebernehmen (+ Einnahme / - Ausgabe).
        v_signed := (CASE WHEN v_row.amount < 0 THEN -1 ELSE 1 END) * v_amount;
        -- Validity-Split ueber den gemeinsamen Helfer (Guards + Vererbung dort; {ok:false} = kein Write).
        v_core := finance.fn_split_recurring_payment(
            v_id, v_eff_from, v_signed, NULL, NULL, v_dom, NULLIF(p->>'name', ''), NULLIF(p->>'notes', ''), v_to);
        IF (v_core->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_core;
        END IF;
        v_new_id := (v_core->>'recurring_payment_id')::int;
        -- Ein mitgenannter Status gilt fuer die neue Zeile ("laeuft wieder, ab 1.11. 3200"); sonst erbt sie den alten.
        IF v_status IS NOT NULL THEN
            UPDATE finance.recurring_payments SET status = v_status WHERE id = v_new_id;
        END IF;
        -- executed_by: die neue Zeile erbt im Split den alten Wert; eine mitgenannte Angabe gilt fuer die neue Zeile und alle
        -- noch laufenden Glieder (gleiche Regel wie im In-Place-Zweig)
        IF v_exec IS NOT NULL THEN
            UPDATE finance.recurring_payments SET executed_by = v_exec
             WHERE id = v_new_id
                OR (id IN (SELECT finance.fn_recurring_lineage(v_new_id))
                    AND (valid_to IS NULL OR valid_to > core.fn_today()));
        END IF;
        v_core := jsonb_build_object('ok', true, 'recurring_payment_id', v_new_id, 'split', true, 'previous_id', v_id);
    ELSE
        -- Neuer Buchungstag: jeder Monat behaelt genau einen Termin (fn_recurring_day_shift). Regel wie fn_change_owned_recurring:
        -- noch nichts erledigt und vor heute nichts faellig -> Neu-Anker in place (Start zieht auf den neuen Tag im Startmonat
        -- mit, fn_recurring_reanchor_day). Sonst bleiben erledigte und ueberfaellige Termine am alten Tag -> Split ab
        -- max(heute, letzter erledigter Termin + 1); die uebrigen Felder gelten dann fuer die neue Zeile.
        IF v_day_moves THEN
            SELECT max(x.d) INTO v_done FROM (
                SELECT max(recurring_due_date) AS d FROM finance.transactions WHERE recurring_payment_id = v_id
                UNION ALL
                SELECT max(due_date) FROM finance.recurring_payment_skips WHERE recurring_payment_id = v_id) x;
            IF v_done IS NULL AND NOT EXISTS (SELECT 1 FROM finance.fn_schedule_occurrences(
                   v_row.first_payment_date, v_row.schedule_interval, v_row.schedule_unit, v_row.schedule_day_of_month,
                   v_row.schedule_days_of_month, v_row.valid_from, core.fn_today() - 1)) THEN
                PERFORM finance.fn_recurring_reanchor_day(v_id, v_dom);
            ELSE
                v_core := finance.fn_split_recurring_payment(v_id, GREATEST(core.fn_today(), v_done + 1), NULL, NULL, NULL,
                    v_dom, NULLIF(p->>'name', ''), NULLIF(p->>'notes', ''), v_to);
                IF (v_core->>'ok')::boolean IS DISTINCT FROM true THEN
                    RETURN v_core;
                END IF;
                v_prev_id := v_id;
                v_id := (v_core->>'recurring_payment_id')::int;
            END IF;
        END IF;
        -- in place (kein Betrag); until_free_money: Ende aus der Projektion, Ablehnung rollt alles zurueck
        BEGIN
            UPDATE finance.recurring_payments SET
                name                  = COALESCE(NULLIF(p->>'name', ''), name),
                status                = COALESCE(v_status, status),
                valid_to              = COALESCE(v_to, valid_to),
                schedule_day_of_month = COALESCE(v_dom, schedule_day_of_month),
                notes                 = COALESCE(NULLIF(p->>'notes', ''), notes)
            WHERE id = v_id;
            -- Status gilt fuer die Zahlung, nicht fuer ein Glied (Kaskade wie fn_set_savings_plan): sonst lebt eine pausierte
            -- Zahlung ueber ihren aktiven Nachfolger weiter (fn_recurring_effective). Pausieren = alle nicht beendeten Glieder,
            -- Fortsetzen = dieses und die spaeteren (ein frueheres pausiertes Glied bleibt Geschichte).
            IF v_status IS NOT NULL THEN
                UPDATE finance.recurring_payments SET status = v_status
                WHERE id IN (SELECT finance.fn_recurring_lineage(v_id)) AND id <> v_id
                  AND (valid_to IS NULL OR valid_to > CURRENT_DATE)
                  AND (v_status <> 'active' OR valid_from > v_row.valid_from);
            END IF;
            -- executed_by gilt fuer die Zahlung, nicht fuer ein Glied: dieses und alle noch laufenden Glieder der Kette
            IF v_exec IS NOT NULL THEN
                UPDATE finance.recurring_payments SET executed_by = v_exec
                 WHERE id = v_id
                    OR (id IN (SELECT finance.fn_recurring_lineage(v_id))
                        AND (valid_to IS NULL OR valid_to > core.fn_today()));
            END IF;
            IF v_free THEN
                v_end := finance.fn_transfer_free_end(v_id);
                IF (v_end->>'ok')::boolean IS DISTINCT FROM true THEN
                    RAISE EXCEPTION USING ERRCODE = 'LA002', MESSAGE = 'until_free_money rejected';
                END IF;
                v_end := v_end - 'ok' - 'horizon_end';
            END IF;
        EXCEPTION WHEN SQLSTATE 'LA002' THEN
            RETURN v_end;
        END;
        v_core := jsonb_build_object('ok', true, 'recurring_payment_id', v_id, 'split', v_prev_id IS NOT NULL)
               || CASE WHEN v_prev_id IS NOT NULL THEN jsonb_build_object('previous_id', v_prev_id) ELSE '{}'::jsonb END;
    END IF;
    -- Ab welchem Termin Betrag/Tag gelten: aus der DB, nie vom Modell abgeleitet (Karte + Antwort lesen es read-only)
    IF v_amount IS NOT NULL OR v_day_moves THEN
        v_core := v_core || jsonb_build_object('first_due',
            finance.fn_recurring_first_due((v_core->>'recurring_payment_id')::int));
    END IF;

    -- Cashflow-Sofort-Hinweis (Event-Fold, geteilt von beiden Erfolgs-Zweigen). Post-State nach dem
    -- Write aus monthly_cashflow_summary. Stichtag-Grenze: bei zukuenftig datierter Erhoehung bleibt die alte
    -- Zeile massgeblich (fn_recurring_effective: laufendes aktives Glied vor dem Nachfolger) -> die Live-View zeigt den
    -- noch geltenden Ist-Stand, der Fold feuert korrekterweise jetzt nicht; der periodische Cron faengt es, wenn der
    -- Stichtag erreicht ist. Bei Stichtag heute spiegelt die View exakt die neue Zeile; laeuft die Zahlung gerade nicht
    -- (pausiert, „laeuft wieder ab ...“), zaehlt die neue Zeile, sobald sie im Fenster liegt. Der eine Fold-Helfer
    -- fn_cashflow_coverage_fold (Pflichtausgaben > Einnahmen, gelatcht, Re-Arm bei Erholung; geteilt mit
    -- fn_create_recurring_payment) -> Note (advisory, nicht-blockierend).
    -- Ausfuehrung eines Uebertrags (Schlusssatz der Karte) als eigenes Feld, nicht unter effective (siehe Header)
    IF v_row.target_account_id IS NOT NULL THEN
        v_core := v_core || jsonb_build_object('execution',
            finance.fn_transfer_executed_by((v_core->>'recurring_payment_id')::int));
    END IF;
    -- Bank-Hinweis: Aussetzen/Beenden -> bank_stop, Betrag/Tag/Fortsetzen -> bank_change; until_free_money hat seinen
    -- eigenen Schlusssatz im Workflow, Name/Notiz und unveraenderte Werte (gleicher Status/Tag) aendern bei der Bank nichts
    v_core := v_core || jsonb_build_object('card_lines', CASE
        WHEN v_free THEN (SELECT '[]'::jsonb FROM finance.fn_bank_note_recorded((v_core->>'recurring_payment_id')::int, 'bank_change'))
        WHEN (v_status = 'paused' AND v_row.status <> 'paused') OR v_to IS NOT NULL
            THEN finance.fn_bank_stop_note_told((v_core->>'recurring_payment_id')::int)
        WHEN v_amount IS NOT NULL OR (v_dom IS NOT NULL AND v_dom IS DISTINCT FROM v_row.schedule_day_of_month)
             OR (v_status = 'active' AND v_row.status <> 'active')
            THEN finance.fn_bank_note_recorded((v_core->>'recurring_payment_id')::int, 'bank_change')
        ELSE '[]'::jsonb END);
    RETURN v_core || jsonb_build_object('effective', COALESCE(v_dates->'resolved', '{}'::jsonb) || v_end)
                  || finance.fn_cashflow_coverage_fold(p->>'chat_id');
END;
$$;
