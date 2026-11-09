-- ============================================================
-- fn_set_recurring_payment (ATOMIC WRITE) -- nur STANDALONE-Zeilen
--   Aendert eine standalone wiederkehrende Einnahme/Ausgabe (Gehalt/Miete/Abo/Rente).
--   STANDALONE-GUARD (Befund B): ist die Zeile (bzw. der Kopf ihrer Kette) von einer Entitaet besessen (insurance/loan/
--   savings_goal/pension/savings_plan -> recurring_payment_id, fn_recurring_owner), wird abgelehnt ({ok:false}) -> Aenderung
--   ueber das jeweilige set_<entity>-Tool (sonst Verwaisen der FK beim Split).
--   BETRAGS-AENDERUNG = history-erhaltender VALIDITY-SPLIT (Best Practice "effective date") ueber den
--   gemeinsamen Helfer fn_split_recurring_payment (Vorzeichen aus der alten Zeile; Ziel-Konto, Status, Ende,
--   Rhythmus-Anker geerbt; Guards s. dort). Sonst (kein amount) IN-PLACE: status (pause/resume),
--   valid_to (beenden), name, schedule_day_of_month, notes.
--   valid_to-EINGABE ist INKLUSIV (letzter gueltiger Tag, wie der Nutzer es sagt); gespeichert wird
--   EXKLUSIV (+1 Tag, Konvention [valid_from, valid_to) -> Audit F2a). Das LLM rechnet nicht.
--   Eingabe jsonb: recurring_payment_id (im n8n aufgeloest), amount (positiver Betrag -> Split),
--   valid_from (Stichtag des Splits; default heute), status, valid_to, schedule_day_of_month,
--   name, notes, until_free_money (true: das Ende setzt die DB, fn_transfer_free_end; nur freistehende Uebertraege,
--   nicht zusammen mit amount oder valid_to; Ablehnung rollt das Update per Savepoint zurueck, LA002).
--   executed_by (opt, bank|manual): Nutzerangabe zu einem Uebertrag (Dauerauftrag bei der Bank oder der Nutzer ueberweist
--   selbst; leer = unveraendert). Wird auf ALLE noch laufenden Glieder der Kette geschrieben (Berater-Alarm liest den Kopf,
--   die Uebersicht das gueltige Glied: beide muessen dasselbe zeigen) und mit amount zusaetzlich auf die neue Split-Zeile;
--   nur an Uebertraegen (Zeile mit Ziel-Konto), sonst {ok:false}. Steuert nur Hinweise, nie die Buchung.
--   RUECKGABE: {ok:true, recurring_payment_id, split}; bei split=true zusaetzlich previous_id; bei einem Uebertrag zusaetzlich
--   execution (aufgeloest bank|manual|unknown, fn_transfer_executed_by; EIGENES Feld, nicht unter effective: das Gate mischt
--   effective in den echten Write); card_lines = Bank-Hinweis (fn_bank_setup_note: pausieren/valid_to -> bank_stop,
--   amount/schedule_day_of_month/Fortsetzen -> bank_change; nicht bei until_free_money, Name/Notiz, executed_by manual).
--   Korrigierbar (entitaets-besessen, amount<=0, ungueltiger executed_by oder an einem
--   Nicht-Uebertrag, Split-Guards des Helfers inkl. last_booked) -> {ok:false}.
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
    v_core     JSONB;     -- Phase L WS-3: Erfolgs-Kern beider Zweige (Split/In-Place) vor dem Cashflow-Fold
    v_dates    JSONB;
    v_free     BOOLEAN := COALESCE(NULLIF(p->>'until_free_money', '')::boolean, false);
    v_end      JSONB   := '{}'::jsonb;
    v_exec     TEXT    := NULLIF(p->>'executed_by', '');
BEGIN
    -- relative Datumsangaben ("in 1 month") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['valid_from', 'valid_to']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_from := NULLIF(p->>'valid_from', '')::date;
    v_to   := NULLIF(p->>'valid_to', '')::date + 1;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    SELECT * INTO v_row FROM finance.recurring_payments WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment % not found.', v_id;
    END IF;

    -- Standalone-Guard (Befund B): entitaets-besessene Zeilen -> ueber das set_<entity>-Tool. Die eine Besitzer-Abfrage
    -- fn_recurring_owner erkennt auch Vorgaenger-Glieder einer Entitaets-Kette (WP2: Kopf-Regel).
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

    IF v_amount IS NOT NULL THEN
        -- BETRAGS-AENDERUNG -> Validity-Split
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
        -- Ein mitgenannter Status gilt fuer die NEUE Zeile ("laeuft wieder, ab 1.11. 3200"); sonst erbt sie den alten.
        IF v_status IS NOT NULL THEN
            UPDATE finance.recurring_payments SET status = v_status WHERE id = v_new_id;
        END IF;
        -- executed_by: die neue Zeile erbt im Split den alten Wert; eine mitgenannte Angabe gilt fuer die neue Zeile UND alle
        -- noch laufenden Glieder (gleiche Regel wie im In-Place-Zweig)
        IF v_exec IS NOT NULL THEN
            UPDATE finance.recurring_payments SET executed_by = v_exec
             WHERE id = v_new_id
                OR (id IN (SELECT finance.fn_recurring_lineage(v_new_id))
                    AND (valid_to IS NULL OR valid_to > core.fn_today()));
        END IF;
        v_core := jsonb_build_object('ok', true, 'recurring_payment_id', v_new_id, 'split', true, 'previous_id', v_id);
    ELSE
        -- IN-PLACE-Aenderung (kein Betrag); until_free_money: Ende aus der Projektion, Ablehnung rollt alles zurueck
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
        v_core := jsonb_build_object('ok', true, 'recurring_payment_id', v_id, 'split', false);
    END IF;

    -- Phase L WS-3: Cashflow-Sofort-Hinweis (Event-Fold, geteilt von beiden Erfolgs-Zweigen). Post-State NACH dem
    -- Write aus monthly_cashflow_summary. M3 (Stichtag-Grenze): bei ZUKUENFTIG datierter Erhoehung bleibt die ALTE
    -- Zeile massgeblich (fn_recurring_effective: laufendes aktives Glied vor dem Nachfolger) -> die Live-View zeigt den
    -- noch geltenden Ist-Stand, der Fold feuert korrekterweise JETZT NICHT; der periodische Cron faengt es, wenn der
    -- Stichtag erreicht ist. Bei Stichtag HEUTE spiegelt die View exakt die neue Zeile; laeuft die Zahlung gerade nicht
    -- (pausiert, „laeuft wieder ab ...“), zaehlt die neue Zeile, sobald sie im Fenster liegt. Audit Paket 3: der eine Fold-Helfer
    -- fn_cashflow_coverage_fold (Pflichtausgaben > Einnahmen, gelatcht, Re-Arm bei Erholung; geteilt mit
    -- fn_create_recurring_payment) -> Note (advisory, nicht-blockierend).
    -- Ausfuehrung eines Uebertrags (Schlusssatz der Karte) als EIGENES Feld, nicht unter effective (siehe Header)
    IF v_row.target_account_id IS NOT NULL THEN
        v_core := v_core || jsonb_build_object('execution',
            finance.fn_transfer_executed_by((v_core->>'recurring_payment_id')::int));
    END IF;
    -- Bank-Hinweis: Aussetzen/Beenden -> bank_stop, Betrag/Tag/Fortsetzen -> bank_change; until_free_money hat seinen
    -- eigenen Schlusssatz im Workflow, Name/Notiz und unveraenderte Werte (gleicher Status/Tag) aendern bei der Bank nichts
    v_core := v_core || jsonb_build_object('card_lines', CASE
        WHEN v_free THEN '[]'::jsonb
        WHEN (v_status = 'paused' AND v_row.status <> 'paused') OR v_to IS NOT NULL
            THEN finance.fn_bank_stop_note_told((v_core->>'recurring_payment_id')::int)
        WHEN v_amount IS NOT NULL OR (v_dom IS NOT NULL AND v_dom IS DISTINCT FROM v_row.schedule_day_of_month)
             OR (v_status = 'active' AND v_row.status <> 'active')
            THEN finance.fn_bank_setup_note((v_core->>'recurring_payment_id')::int, 'bank_change')
        ELSE '[]'::jsonb END);
    RETURN v_core || jsonb_build_object('effective', COALESCE(v_dates->'resolved', '{}'::jsonb) || v_end)
                  || finance.fn_cashflow_coverage_fold(p->>'chat_id');
END;
$$;
