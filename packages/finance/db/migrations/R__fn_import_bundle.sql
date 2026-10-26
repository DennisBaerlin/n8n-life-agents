-- ============================================================
-- fn_import_bundle (ATOMIC WRITE — der EINE Commit der Bulk-Import-Pipeline, Phase 2)
--   Loop ueber die BESTEHENDEN fn_create_*/fn_book_* (= die getestete Validierungs-
--   Oberflaeche, keine Duplikation) in Abhaengigkeits-Reihenfolge:
--   account -> real_estate -> loan -> Rest (insurance/pension/recurring/savings_goal/stock_buy).
--   Namen->ID-Aufloesung passiert HIER (Staging traegt rohe Namen): zuerst gegen die in
--   DIESEM Lauf erzeugten Konten (In-Batch-Referenzen), sonst fn_resolve_* (0/>1 = Fehler).
--
--   ATOMARITAET (R7-Vertrag, review-konform umgesetzt): der gesamte Write-Loop laeuft in
--   einem inneren BEGIN/EXCEPTION-Block (= Savepoint). Jedes innere {ok:false} wird
--   GESAMMELT und am Ende in ein RAISE uebersetzt -> der Block rollt ALLE Writes zurueck;
--   der Handler gibt {ok:false, errors:[{row_no, error}]} als DATEN zurueck (kein RAISE
--   nach aussen -> kein Owner-Alert; Staging bleibt intakt -> Re-Approval = 1 Button).
--   Auch unerwartete Exceptions (RAISE einer Ziel-fn, CHECK/Trigger) werden so zum
--   freundlichen per-Row-Fehler.
--
--   Gleicher Feldumfang wie die Einzel-Tools: opening_balance reicht das Bundle an fn_create_account
--   durch (dort die EINE Eroeffnungsbuchung); Personen-Felder (owner_person/policyholder_person/
--   borrower_person/beneficiary_person) loest fn_import_resolve_persons je Zeile erneut auf (kein TOCTOU);
--   stock_buy-Zeilen sind BESTANDSUEBERNAHMEN (existing_position=true): der Verrechnungskonto-Saldo
--   bleibt der genannte Stand. Gedruckte Depotnummer/Inhaber prueft fn_import_depot_conflict erneut; einem Depot
--   ohne Nummer traegt fn_set_account die gedruckte Nummer nach (fn_import_depot_number_to_store, die Karte zeigt es).
--
--   RUECKGABE (Post-State-Vertrag): {ok:true, committed, created:[{row_no, entity_type,
--   id, balance?, currency?}]} — ids = Handles, committed-Count = Informationsgehalt der Batch-Op,
--   balance = Konto-Saldo nach Anlage bzw. Verrechnungssaldo nach Uebernahme; currency (Konten) fuer den
--   FX-Sofort-Refresh des Tools; positions:[{holding_id, name, symbol, isin, provider_symbol, quote_currency, asset_class}] =
--   Post-State der uebernommenen Depot-Positionen (Monats-Check WP-G: das Tool prueft danach, ob jede Position einen
--   Kurs hat und eine Anlageklasse traegt, und der Agent klaert Luecken mit dem Nutzer).
--   | {ok:false, errors:[...], reason}.
--
--   PROBELAUF (dry_run:true, Import-Haertung 2026-10-22): tool_commit_import ruft das Bundle VOR der Karte einmal
--   als Probelauf -> derselbe Write-Loop ueber dieselben fn_create_*/fn_book_* (keine zweite Regel-Liste, die zur
--   Validierung driften kann), am Ende IMMER zurueckgerollt (Staging-Status unveraendert). Fehlerfrei ->
--   {ok:true, dry_run:true}; sonst {ok:false, dry_run:true, errors, error_summary, reason} -> keine Karte.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_bundle(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_batch     UUID := (p->>'batch_id')::uuid;
    v_total     INT;
    v_not_valid INT;
    v_committed INT;
    v_errors    JSONB := '[]'::jsonb;
    v_created   JSONB := '[]'::jsonb;
    v_positions JSONB := '[]'::jsonb;
    v_row       RECORD;
    v_cur_row   INT;
    v_acct_map  JSONB := '{}'::jsonb;   -- lower(name) -> {id, settlement_id} der in DIESEM Lauf erzeugten Konten
    v_re_map    JSONB := '{}'::jsonb;   -- lower(name) -> real_estate_id (dieser Lauf)
    v_pen_map   JSONB := '{}'::jsonb;   -- lower(name) -> pension_id (dieser Lauf)
    v_r         JSONB;
    v_res       JSONB;
    v_payload   JSONB;
    v_id        INT;
    v_ref_id    INT;
    v_settle    INT;
    v_err       TEXT;
    v_depot_no  TEXT;                  -- gedruckte Depotnummer, die am Depot nachgetragen wird (fn_import_depot_number_to_store)
    v_rollback_intended BOOLEAN := FALSE;   -- A2: Klassifikation per Flag, NICHT per SQLERRM-Stringmatch
    v_dry       BOOLEAN := COALESCE(NULLIF(p->>'dry_run', '')::boolean, false);   -- Probelauf vor der Karte
    v_dry_ok    BOOLEAN := FALSE;
    v_summary   TEXT;
BEGIN
    -- ---------- Guards (reine Reads, vor dem atomaren Block) ----------
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE status <> 'valid' AND status <> 'committed'),
           COUNT(*) FILTER (WHERE status = 'committed')
    INTO v_total, v_not_valid, v_committed
    FROM finance.import_staging WHERE batch_id = v_batch;

    IF v_total = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'batch not found or empty');
    END IF;
    IF v_committed > 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'this batch is already committed');
    END IF;
    IF v_not_valid > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('%s row(s) are not valid — fix them first (see validation_error per row)', v_not_valid));
    END IF;

    -- ---------- atomarer Write-Block (BEGIN/EXCEPTION = Savepoint: Fehler rollt ALLES zurueck) ----------
    BEGIN
        FOR v_row IN
            SELECT * FROM finance.import_staging
            WHERE batch_id = v_batch AND status = 'valid'
            ORDER BY CASE entity_type
                         WHEN 'account'           THEN 0
                         WHEN 'real_estate'       THEN 1
                         WHEN 'loan'              THEN 2
                         WHEN 'pension_statement' THEN 4   -- NACH den Pensions (In-Batch-Referenz)
                         ELSE 3 END,
                     row_no
            FOR UPDATE
        LOOP
            v_cur_row := v_row.row_no;
            v_payload := v_row.payload;
            v_err     := NULL;

            -- Personen-Feld -> *_person_id (dieselbe Aufloesung wie validate_row, hier erneut: kein TOCTOU)
            v_res := finance.fn_import_resolve_persons(v_row.entity_type, v_payload);
            IF v_res->>'error' IS NOT NULL THEN
                v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_res->>'error');
                CONTINUE;
            END IF;
            v_payload := v_res->'payload';

            IF v_row.entity_type = 'account' THEN
                v_settle := NULL;
                IF NULLIF(v_payload->>'settlement_account','') IS NOT NULL THEN
                    v_res    := finance.fn_import_resolve_account(v_payload->>'settlement_account', v_acct_map);
                    v_settle := NULLIF(v_res->>'id','')::int;
                    v_err    := v_res->>'error';
                END IF;
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                -- Eroeffnungssaldo macht fn_create_account selbst (EINE Adresse mit dem Einzel-Tool:
                -- category='other', kein Reconcile-Stempel, opening_balance_date = heute).
                v_r := finance.fn_create_account(
                    (v_payload - 'settlement_account')
                    || CASE WHEN v_settle IS NULL THEN '{}'::jsonb
                            ELSE jsonb_build_object('settlement_id', v_settle) END);
                IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_id := (v_r->>'account_id')::int;
                v_acct_map := v_acct_map || jsonb_build_object(
                    lower(v_payload->>'name'),
                    jsonb_build_object('id', v_id, 'settlement_id', v_settle));
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'account', 'id', v_id, 'balance', (v_r->>'balance')::numeric,
                    'currency', (SELECT currency FROM finance.accounts WHERE id = v_id));

            ELSIF v_row.entity_type = 'real_estate' THEN
                v_r := finance.fn_create_real_estate(v_payload);
                IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN   -- Import-Haertung: abgelehnt != angelegt
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_id := (v_r->>'real_estate_id')::int;
                v_re_map := v_re_map || jsonb_build_object(lower(v_payload->>'name'), v_id);
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'real_estate', 'id', v_id);

            ELSIF v_row.entity_type = 'loan' THEN
                v_res    := finance.fn_import_resolve_account(v_payload->>'debit_account', v_acct_map);
                v_ref_id := NULLIF(v_res->>'id','')::int;
                v_err    := v_res->>'error';
                v_settle := NULL;
                IF v_err IS NULL AND NULLIF(v_payload->>'disbursement_account','') IS NOT NULL THEN
                    v_res    := finance.fn_import_resolve_account(v_payload->>'disbursement_account', v_acct_map);
                    v_settle := NULLIF(v_res->>'id','')::int;
                    v_err    := v_res->>'error';
                END IF;
                v_id := NULL;
                IF v_err IS NULL AND NULLIF(v_payload->>'real_estate','') IS NOT NULL THEN
                    v_id := NULLIF(v_re_map->>lower(v_payload->>'real_estate'),'')::int;
                    IF v_id IS NULL THEN
                        SELECT r.id INTO v_id FROM finance.fn_resolve_real_estate(v_payload->>'real_estate', FALSE) r;
                    END IF;
                    IF v_id IS NULL THEN v_err := format('real_estate "%s" not found', v_payload->>'real_estate'); END IF;
                END IF;
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                v_r := finance.fn_create_loan(
                    (v_payload - 'debit_account' - 'disbursement_account' - 'real_estate')
                    || jsonb_build_object('debit_account_id', v_ref_id)
                    || CASE WHEN v_settle IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('disbursement_account_id', v_settle) END
                    || CASE WHEN v_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('real_estate_id', v_id) END);
                IF (v_r ? 'ok') AND (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'loan', 'id', (v_r->>'loan_id')::int);

            ELSIF v_row.entity_type = 'insurance' THEN
                v_res    := finance.fn_import_resolve_account(v_payload->>'debit_account', v_acct_map);
                v_ref_id := NULLIF(v_res->>'id','')::int;
                v_err    := v_res->>'error';
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                v_r := finance.fn_create_insurance(
                    (v_payload - 'debit_account') || jsonb_build_object('debit_account_id', v_ref_id));
                IF (v_r ? 'ok') AND (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'insurance', 'id', (v_r->>'insurance_id')::int);

            ELSIF v_row.entity_type = 'pension' THEN
                v_ref_id := NULL;
                IF NULLIF(v_payload->>'debit_account','') IS NOT NULL THEN
                    v_res    := finance.fn_import_resolve_account(v_payload->>'debit_account', v_acct_map);
                    v_ref_id := NULLIF(v_res->>'id','')::int;
                    v_err    := v_res->>'error';
                    IF v_err IS NOT NULL THEN
                        v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                        CONTINUE;
                    END IF;
                END IF;
                v_r := finance.fn_create_pension(
                    (v_payload - 'debit_account')
                    || CASE WHEN v_ref_id IS NULL THEN '{}'::jsonb
                            ELSE jsonb_build_object('debit_account_id', v_ref_id) END);
                IF (v_r ? 'ok') AND (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_pen_map := v_pen_map || jsonb_build_object(lower(v_payload->>'name'), (v_r->>'pension_id')::int);
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'pension', 'id', (v_r->>'pension_id')::int);

            ELSIF v_row.entity_type = 'recurring_payment' THEN
                v_res    := finance.fn_import_resolve_account(v_payload->>'account', v_acct_map);
                v_ref_id := NULLIF(v_res->>'id','')::int;
                v_err    := v_res->>'error';
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                v_r := finance.fn_create_recurring_payment(
                    (v_payload - 'account') || jsonb_build_object('account_id', v_ref_id));
                IF (v_r ? 'ok') AND (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'recurring_payment', 'id', (v_r->>'recurring_payment_id')::int);

            ELSIF v_row.entity_type = 'savings_goal' THEN
                v_res    := finance.fn_import_resolve_account(v_payload->>'account', v_acct_map);
                v_ref_id := NULLIF(v_res->>'id','')::int;
                v_err    := v_res->>'error';
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                -- Audit Paket 3: Sparkonto (Topf) ist Pflicht -> wie das Abbuchungskonto aufloesen (auch batch-intern).
                v_res := finance.fn_import_resolve_account(v_payload->>'reserve_account', v_acct_map);
                v_err := v_res->>'error';
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                v_r := finance.fn_create_savings_goal(
                    (v_payload - 'account' - 'reserve_account')
                    || jsonb_build_object('account_id', v_ref_id, 'reserve_account_id', NULLIF(v_res->>'id','')::int));
                IF (v_r ? 'ok') AND (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'savings_goal', 'id', (v_r->>'goal_id')::int);

            ELSIF v_row.entity_type = 'stock_buy' THEN
                v_res    := finance.fn_import_resolve_account(v_payload->>'depot', v_acct_map);
                v_ref_id := NULLIF(v_res->>'id','')::int;
                v_err    := v_res->>'error';
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                v_settle := COALESCE(
                    NULLIF(v_acct_map->lower(v_payload->>'depot')->>'settlement_id','')::int,
                    (SELECT settlement_account_id FROM finance.accounts WHERE id = v_ref_id));
                IF v_settle IS NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row,
                        'error', format('depot "%s" has no settlement account', v_payload->>'depot'));
                    CONTINUE;
                END IF;
                -- gedruckte Depotnummer/Inhaber erneut gegen das Depot (wie validate_row, kein TOCTOU)
                v_err := finance.fn_import_depot_conflict(v_batch, v_payload);
                IF v_err IS NOT NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_err);
                    CONTINUE;
                END IF;
                -- Depot ohne Nummer: die gedruckte Nummer mitspeichern (Karte zeigt es, dieselbe Bedingung in
                -- fn_import_card_rows); fn_set_account prueft die Eindeutigkeit -> {ok:false} -> Zeilenfehler/Rollback
                v_depot_no := finance.fn_import_depot_number_to_store(v_batch, v_payload);
                IF v_depot_no IS NOT NULL THEN
                    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_ref_id, 'account_number', v_depot_no));
                    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                        v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                        CONTINUE;
                    END IF;
                END IF;
                -- Kurs-Notierung in Fremdwaehrung (provider_currency, tool_commit_import): wird die native Markt-Waehrung
                -- der EUR-Position (quote_currency, WP-3a) -> fn_active_currencies holt den FX-Kurs; ein genannter
                -- Kaufkurs-quote_currency geht vor (der Einstand bleibt in Depot-Waehrung, nichts wird umgerechnet).
                IF NULLIF(v_payload->>'quote_currency', '') IS NULL AND NULLIF(v_payload->>'provider_currency', '') IS NOT NULL THEN
                    v_payload := v_payload || jsonb_build_object('quote_currency', v_payload->>'provider_currency');
                END IF;
                v_r := finance.fn_book_stock_buy(
                    (v_payload - 'depot' - 'depot_number' - 'depot_holder' - 'provider_currency')
                    || jsonb_build_object('depot_id', v_ref_id, 'settlement_id', v_settle,
                        'existing_position', true,   -- Import = heutiger Bestand: Saldo bleibt der genannte Stand
                        'transaction_date', COALESCE(NULLIF(v_payload->>'transaction_date',''),
                                                     to_char(CURRENT_DATE,'YYYY-MM-DD'))));
                IF (v_r ? 'ok') AND (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row, 'error', v_r->>'reason');
                    CONTINUE;
                END IF;
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'stock_buy', 'id', (v_r->>'buy_tx_id')::int,
                    'balance', (v_r->>'settlement_balance')::numeric);
                v_positions := v_positions || (
                    SELECT jsonb_build_object('holding_id', h.id, 'name', h.name, 'symbol', h.symbol, 'isin', h.isin,
                                              'provider_symbol', h.provider_symbol, 'quote_currency', h.quote_currency,
                                              'asset_class', h.asset_class)
                    FROM finance.depot_holdings h WHERE h.id = (v_r->>'holding_id')::int);

            ELSIF v_row.entity_type = 'pension_statement' THEN
                -- Pension aufloesen: die von fn_import_stage gesetzte pension_id (Folgebescheid), sonst In-Batch, sonst
                -- Bestand (fn_resolve_pension)
                v_id := COALESCE(NULLIF(v_payload->>'pension_id','')::int, NULLIF(v_pen_map->>lower(v_payload->>'pension'),'')::int);
                IF v_id IS NULL THEN
                    SELECT r.id INTO v_id FROM finance.fn_resolve_pension(v_payload->>'pension', FALSE) r
                    WHERE r.hit_count = 1;
                END IF;
                IF v_id IS NULL THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row,
                        'error', format('pension "%s" not found or ambiguous', v_payload->>'pension'));
                    CONTINUE;
                END IF;
                BEGIN
                    INSERT INTO finance.pension_statements
                        (pension_id, statement_date, reached_claim, projection, scenario_1pct, scenario_2pct, em_monthly,
                         earning_points, regular_retirement_date, notes)
                    VALUES (v_id,
                            (v_payload->>'statement_date')::date,
                            NULLIF(v_payload->>'reached_claim','')::numeric,
                            NULLIF(v_payload->>'projection','')::numeric,
                            NULLIF(v_payload->>'scenario_1pct','')::numeric,
                            NULLIF(v_payload->>'scenario_2pct','')::numeric,
                            NULLIF(v_payload->>'em_monthly','')::numeric,
                            NULLIF(v_payload->>'earning_points','')::numeric,
                            NULLIF(v_payload->>'regular_retirement_date','')::date,
                            NULLIF(v_payload->>'notes',''))
                    RETURNING id INTO v_ref_id;
                EXCEPTION WHEN unique_violation THEN
                    v_errors := v_errors || jsonb_build_object('row_no', v_cur_row,
                        'error', format('a statement dated %s already exists for this pension', v_payload->>'statement_date'));
                    CONTINUE;
                END;
                v_created := v_created || jsonb_build_object('row_no', v_cur_row,
                    'entity_type', 'pension_statement', 'id', v_ref_id);
            END IF;
        END LOOP;

        -- alles-oder-nichts: jeder gesammelte Fehler erzwingt den Voll-Rollback dieses Blocks
        IF jsonb_array_length(v_errors) > 0 THEN
            -- A2: Flag VOR dem RAISE setzen -> der Handler unterscheidet "gewollter Sammel-
            -- Rollback" von einer unerwarteten Exception OHNE SQLERRM-Stringmatch (der bei
            -- Rename/Lokalisierung still bricht — largerEqual-Bug-Klasse). Variablen-
            -- Zuweisungen werden beim Block-Rollback NICHT zurueckgenommen (Speicher, nicht TX).
            v_rollback_intended := TRUE;
            RAISE EXCEPTION 'import rollback (% row error(s))', jsonb_array_length(v_errors);
        END IF;

        -- Probelauf: derselbe Write-Loop, dann IMMER zurueckrollen (Flag + RAISE wie oben); v_dry_ok ueberlebt
        -- den Rollback (Variable, nicht TX) und unterscheidet "fehlerfrei" vom Fehlerfall im Handler.
        IF v_dry THEN
            v_dry_ok := TRUE;
            v_rollback_intended := TRUE;
            RAISE EXCEPTION 'import dry run (always rolled back)';
        END IF;

        UPDATE finance.import_staging
        SET status = 'committed', validation_error = NULL
        WHERE batch_id = v_batch;

    EXCEPTION WHEN OTHERS THEN
        IF v_dry_ok THEN
            RETURN jsonb_build_object('ok', true, 'dry_run', true);
        END IF;
        IF NOT v_rollback_intended THEN
            -- unerwartete Exception einer Ziel-fn/eines CHECKs: als Row-Fehler benennen
            v_errors := jsonb_build_array(jsonb_build_object('row_no', v_cur_row, 'error', SQLERRM));
        END IF;
        -- A11: formatierte, modell-lesbare Fehlerzeilen (kein roher JSON-Blob im Tool)
        SELECT string_agg('Zeile ' || (e->>'row_no') || ': ' || (e->>'error'), '; ' ORDER BY (e->>'row_no')::int)
        INTO v_summary FROM jsonb_array_elements(v_errors) e;
        RETURN jsonb_build_object('ok', false,
            'dry_run', v_dry,
            'errors', v_errors,
            'error_summary', COALESCE(v_summary, 'unknown error'),
            'reason', CASE WHEN v_dry
                THEN 'no card was sent - the dry run found errors; fix the listed rows with tool_update_staging_row, then call tool_commit_import again'
                ELSE 'import rolled back completely — fix the listed rows, then approve again' END);
    END;

    RETURN jsonb_build_object('ok', true,
        'committed', v_total,
        'created', v_created,
        'positions', v_positions);
END;
$$;

-- ============================================================
-- fn_import_resolve_account — Konto-Name -> ID fuer den Bundle-Lauf:
-- zuerst die in DIESEM Lauf erzeugten Konten (p_map: lower(name)->{id,...}),
-- sonst fn_resolve_account (nur eindeutige Treffer).
-- RUECKGABE: {id: <int|null>, error: <text|null>}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_resolve_account(p_name text, p_map jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_hits INT;
    v_id   INT;
BEGIN
    IF NULLIF(trim(COALESCE(p_name,'')),'') IS NULL THEN
        RETURN jsonb_build_object('id', NULL, 'error', 'account reference is empty');
    END IF;
    IF p_map ? lower(p_name) THEN
        RETURN jsonb_build_object('id', (p_map->lower(p_name)->>'id')::int, 'error', NULL);
    END IF;
    SELECT r.id, r.hit_count INTO v_id, v_hits FROM finance.fn_resolve_account(p_name, NULL, TRUE) r;
    IF v_hits = 1 THEN
        RETURN jsonb_build_object('id', v_id, 'error', NULL);
    ELSIF v_hits = 0 THEN
        RETURN jsonb_build_object('id', NULL, 'error', format('account "%s" not found', p_name));
    ELSE
        RETURN jsonb_build_object('id', NULL, 'error', format('account "%s" is ambiguous (%s matches)', p_name, v_hits));
    END IF;
END;
$$;
