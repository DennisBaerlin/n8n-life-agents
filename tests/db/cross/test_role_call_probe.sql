-- tests/db/cross/test_role_call_probe.sql
-- Rollen-Probe Stufe 2: jede fn, die ein gebauter Workflow unter einer engen Rolle aufruft, wird hier wirklich unter dieser
-- Rolle aufgerufen (SET LOCAL ROLE), mit leerem und mit NULL-Payload. Jede kontrollierte Ablehnung (RAISE, Validierung,
-- NULL-Fehler) ist ok; ein Postgres-eigenes "permission denied" (SQLSTATE 42501) ist ein Fehler. db_test laeuft als
-- Superuser und sieht fehlende Tabellen-/Sequenzrechte sonst nie; zur Laufzeit stuenden sie als "permission denied" in der
-- Bestaetigungskarte. Die Probe deckt nur den Koerper bis zur ersten Validierung ab; Schreibpfade deckt (2) ab.
-- (2) Tabellenrechte im Koerper: jede INVOKER-fn (samt INVOKER-Helfern) schreibt/liest Tabellen; die Rolle braucht dafuer
-- INSERT/UPDATE/DELETE/SELECT und fuer neue Zeilen USAGE auf den Sequenzen der Tabelle. Quelle ist der fn-Text
-- (schema.tabelle und unqualifizierte Tabellen im eigenen Schema; dynamisches SQL sieht der Test nicht). Eine DEFINER-fn
-- laeuft mit Eigentuemer-Rechten und beendet die Kette.
-- Die Paar-Liste erzeugt scripts/role_test_lint.ps1 -WriteCatalog (wie test_role_catalog_exec.sql).
BEGIN;

-- Alle (Schema, fn)-Ueberlagerungen des Aufrufers samt INVOKER-Helfern; Spalte src ist der fn-Text ohne Kommentare/Literale.
CREATE FUNCTION pg_temp.rp_chain(p_schema text, p_fn text, p_skip text[] DEFAULT '{}') RETURNS TABLE (sch text, fn text, oid_ oid, src text)
LANGUAGE plpgsql AS $f$
DECLARE
  v_queue text[] := ARRAY[p_schema || '.' || p_fn];
  v_seen  text[] := '{}';
  v_cur   text;
  r       record;
  h       record;
  v_src   text;
BEGIN
  WHILE coalesce(array_length(v_queue, 1), 0) > 0 LOOP
    v_cur := v_queue[1];
    v_queue := v_queue[2:array_length(v_queue, 1)];
    CONTINUE WHEN v_cur = ANY (v_seen) OR v_cur = ANY (p_skip);
    v_seen := v_seen || v_cur;
    FOR r IN
      SELECT p.oid, p.prosecdef, p.prosrc, n.nspname, p.proname
      FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = split_part(v_cur, '.', 1) AND p.proname = split_part(v_cur, '.', 2) AND p.prokind = 'f'
    LOOP
      CONTINUE WHEN r.prosecdef;
      v_src := regexp_replace(regexp_replace(regexp_replace(r.prosrc, '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g'), '''[^'']*''', '', 'g');
      sch := r.nspname; fn := r.proname; oid_ := r.oid; src := v_src;
      RETURN NEXT;
      FOR h IN
        SELECT DISTINCT m[1] || '.' || m[2] AS q
        FROM regexp_matches(v_src, '\m([a-z][a-z0-9_]*)\.(fn_[a-z0-9_]+)\s*\(', 'g') AS m
        UNION
        SELECT DISTINCT r.nspname || '.' || m[1] AS q
        FROM regexp_matches(v_src, '(?<![.\w])(fn_[a-z0-9_]+)\s*\(', 'g') AS m
      LOOP
        v_queue := v_queue || h.q;
      END LOOP;
    END LOOP;
  END LOOP;
END
$f$;

-- Rechte der Rolle auf die Tabellen, die der fn-Text nennt; liefert fehlende Rechte als Text.
CREATE FUNCTION pg_temp.rp_table_gaps(p_role text, p_schema text, p_fn text, p_skip text[] DEFAULT '{}') RETURNS text[]
LANGUAGE plpgsql AS $f$
DECLARE
  v_out  text[] := '{}';
  c      record;
  m      text[];
  v_sch  text;
  v_tab  text;
  v_oid  oid;
  v_kind text;
  v_priv text;
  s      record;
BEGIN
  FOR c IN SELECT * FROM pg_temp.rp_chain(p_schema, p_fn, p_skip) LOOP
    FOR m IN
      SELECT regexp_matches(c.src, '\m(insert\s+into|update|delete\s+from|from|join)\s+(?:only\s+)?(?:([a-z_][a-z0-9_]*)\.)?([a-z_][a-z0-9_]*)\M', 'gi')
    LOOP
      v_sch := lower(m[2]); v_tab := lower(m[3]);
      v_kind := lower(regexp_replace(m[1], '\s+.*$', ''));
      -- ohne Schema nur Schreib-Anweisungen im eigenen Schema aufloesen; Lesen ohne Schema sind meist CTE-/Alias-Namen
      IF v_sch IS NULL THEN
        CONTINUE WHEN v_kind IN ('from', 'join');
        v_sch := c.sch;
      END IF;
      CONTINUE WHEN v_sch NOT IN ('core', 'agent', 'public', 'finance', 'estate', 'career', 'paperless');
      SELECT cl.oid INTO v_oid FROM pg_class AS cl JOIN pg_namespace AS n ON n.oid = cl.relnamespace
      WHERE n.nspname = v_sch AND cl.relname = v_tab AND cl.relkind IN ('r', 'p', 'v', 'm');
      CONTINUE WHEN v_oid IS NULL;
      v_priv := CASE v_kind WHEN 'insert' THEN 'INSERT' WHEN 'update' THEN 'UPDATE' WHEN 'delete' THEN 'DELETE' ELSE 'SELECT' END;
      IF NOT has_table_privilege(p_role, v_oid, v_priv) THEN
        v_out := v_out || (c.sch || '.' || c.fn || ': ' || p_role || ' hat kein ' || v_priv || ' auf ' || v_sch || '.' || v_tab);
      END IF;
      IF v_kind = 'insert' THEN
        FOR s IN
          SELECT DISTINCT d.objid FROM pg_depend AS d JOIN pg_class AS sq ON sq.oid = d.objid AND sq.relkind = 'S'
          WHERE d.refobjid = v_oid AND d.deptype IN ('a', 'i')
        LOOP
          IF NOT has_sequence_privilege(p_role, s.objid, 'USAGE') THEN
            v_out := v_out || (c.sch || '.' || c.fn || ': ' || p_role || ' hat kein USAGE auf die Sequenz ' || s.objid::regclass::text || ' von ' || v_sch || '.' || v_tab);
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END LOOP;
  RETURN v_out;
END
$f$;

-- Aufruf unter der Rolle; liefert die Fehlermeldung eines Rechte-Fehlers oder NULL.
CREATE FUNCTION pg_temp.rp_call(p_role text, p_call text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  v_state text;
  v_msg   text;
BEGIN
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE 'SELECT ' || p_call;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state = '42501' AND v_msg ~ '^(permission denied|must be owner|new row violates row-level security)' THEN
      RETURN v_msg;
    END IF;
    RETURN NULL;
  END;
  RETURN NULL;
END
$f$;

-- Selbsttest: der Test erkennt ein fehlendes Tabellenrecht, ein fehlendes Sequenzrecht und ein fehlendes Ausfuehrungsrecht,
-- und ein kontrollierter Fehler mit SQLSTATE 42501 zaehlt nicht.
CREATE ROLE rp_probe_role NOLOGIN;
CREATE TABLE public.rp_probe_t (id serial PRIMARY KEY, v text);
CREATE FUNCTION public.fn_rp_probe_w(p jsonb) RETURNS int LANGUAGE plpgsql AS $p$
BEGIN INSERT INTO public.rp_probe_t (v) VALUES (p->>'v'); RETURN 1; END $p$;
CREATE FUNCTION public.fn_rp_probe_own(p jsonb) RETURNS int LANGUAGE plpgsql AS $p$
BEGIN RAISE EXCEPTION 'kontrolliert' USING ERRCODE = 'insufficient_privilege'; END $p$;
GRANT EXECUTE ON FUNCTION public.fn_rp_probe_w(jsonb), public.fn_rp_probe_own(jsonb) TO rp_probe_role;
GRANT USAGE ON SCHEMA public TO rp_probe_role;
DO $t$
DECLARE
  v_g text[];
  v_m text;
BEGIN
  v_g := pg_temp.rp_table_gaps('rp_probe_role', 'public', 'fn_rp_probe_w');
  IF NOT (array_to_string(v_g, ' | ') ~ 'kein INSERT auf public.rp_probe_t') THEN
    RAISE EXCEPTION 'FAIL: fehlendes INSERT-Recht nicht erkannt: %', v_g;
  END IF;
  GRANT INSERT ON public.rp_probe_t TO rp_probe_role;
  v_g := pg_temp.rp_table_gaps('rp_probe_role', 'public', 'fn_rp_probe_w');
  IF NOT (array_to_string(v_g, ' | ') ~ 'kein USAGE auf die Sequenz') THEN
    RAISE EXCEPTION 'FAIL: fehlendes Sequenzrecht nicht erkannt: %', v_g;
  END IF;
  GRANT USAGE ON SEQUENCE public.rp_probe_t_id_seq TO rp_probe_role;
  IF cardinality(pg_temp.rp_table_gaps('rp_probe_role', 'public', 'fn_rp_probe_w')) <> 0 THEN
    RAISE EXCEPTION 'FAIL: Rechte nach dem Grant weiter gemeldet';
  END IF;
  -- Superuser besitzt die Tabelle; ohne Grant scheitert der Aufruf unter der Rolle an permission denied.
  REVOKE INSERT ON public.rp_probe_t FROM rp_probe_role;
  v_m := pg_temp.rp_call('rp_probe_role', 'public.fn_rp_probe_w(''{"v":"x"}''::jsonb)');
  IF v_m IS NULL THEN RAISE EXCEPTION 'FAIL: permission denied unter der Rolle nicht erkannt'; END IF;
  v_m := pg_temp.rp_call('rp_probe_role', 'public.fn_rp_probe_own(''{}''::jsonb)');
  IF v_m IS NOT NULL THEN RAISE EXCEPTION 'FAIL: kontrollierter Fehler mit SQLSTATE 42501 faelschlich gemeldet: %', v_m; END IF;
  GRANT INSERT ON public.rp_probe_t TO rp_probe_role;
  v_m := pg_temp.rp_call('rp_probe_role', 'public.fn_rp_probe_w(''{"v":"x"}''::jsonb)');
  IF v_m IS NOT NULL THEN RAISE EXCEPTION 'FAIL: Aufruf mit allen Rechten gemeldet: %', v_m; END IF;
END
$t$;
RESET ROLE;

DO $t$
DECLARE
  r      record;
  f      record;
  v_args text[];
  v_call text;
  v_msg  text;
  v_bad  text[] := '{}';
  v_gaps text[];
  v_n    int := 0;
  v_calls int := 0;
BEGIN
  FOR r IN
    SELECT role_name, fn_name FROM (VALUES
-- BEGIN GENERATED PAIRS
  ('career_ro', 'core.fn_onboarding_status'),
  ('career_ro', 'core.fn_package_active'),
  ('career_ro', 'core.fn_ui_texts_for'),
  ('career_rw', 'career.fn_read_job_matches'),
  ('context_ro', 'core.fn_fetch_context'),
  ('core_ro', 'agent.fn_chat_style'),
  ('core_ro', 'agent.fn_get_hitl_pending_state'),
  ('core_ro', 'agent.fn_owner_person_id'),
  ('core_ro', 'agent.fn_person_lang'),
  ('core_ro', 'agent.fn_resolve_sender'),
  ('core_ro', 'core.fn_advisor_plan_status'),
  ('core_ro', 'core.fn_daypart'),
  ('core_ro', 'core.fn_get_llm_cost_report'),
  ('core_ro', 'core.fn_get_next_step'),
  ('core_ro', 'core.fn_hitl_texts'),
  ('core_ro', 'core.fn_onboarding_overview'),
  ('core_ro', 'core.fn_reminders_overview'),
  ('core_ro', 'core.fn_render_welcome'),
  ('core_ro', 'core.fn_sender_sees_household'),
  ('core_ro', 'core.fn_smalltalk_kind'),
  ('core_ro', 'core.fn_ui_text'),
  ('core_ro', 'core.fn_ui_texts'),
  ('estate_ro', 'core.fn_onboarding_status'),
  ('estate_ro', 'core.fn_package_active'),
  ('estate_ro', 'core.fn_ui_texts_for'),
  ('estate_rw', 'core.fn_check_write_permission'),
  ('estate_rw', 'core.fn_config_get'),
  ('estate_rw', 'core.fn_dry_run'),
  ('estate_rw', 'core.fn_household_persons'),
  ('estate_rw', 'core.fn_package_active'),
  ('estate_rw', 'core.fn_resolve_person'),
  ('estate_rw', 'core.fn_set_onboarding_section'),
  ('estate_rw', 'core.fn_should_notify'),
  ('estate_rw', 'core.fn_ui_texts_for'),
  ('estate_rw', 'estate.fn_cancel_case'),
  ('estate_rw', 'estate.fn_confirm_review'),
  ('estate_rw', 'estate.fn_create_case'),
  ('estate_rw', 'estate.fn_create_case_task'),
  ('estate_rw', 'estate.fn_create_contact'),
  ('estate_rw', 'estate.fn_create_digital_account'),
  ('estate_rw', 'estate.fn_create_provider_contract'),
  ('estate_rw', 'estate.fn_create_special_asset'),
  ('estate_rw', 'estate.fn_create_storage_place'),
  ('estate_rw', 'estate.fn_delete_contact'),
  ('estate_rw', 'estate.fn_delete_digital_account'),
  ('estate_rw', 'estate.fn_delete_provider_contract'),
  ('estate_rw', 'estate.fn_delete_special_asset'),
  ('estate_rw', 'estate.fn_preview_case'),
  ('estate_rw', 'estate.fn_record_directive'),
  ('estate_rw', 'estate.fn_render_emergency_binder'),
  ('estate_rw', 'estate.fn_resolve_contact'),
  ('estate_rw', 'estate.fn_resolve_digital_account'),
  ('estate_rw', 'estate.fn_resolve_provider_contract'),
  ('estate_rw', 'estate.fn_resolve_special_asset'),
  ('estate_rw', 'estate.fn_resolve_storage_place'),
  ('estate_rw', 'estate.fn_set_case'),
  ('estate_rw', 'estate.fn_set_case_task'),
  ('estate_rw', 'estate.fn_set_contact'),
  ('estate_rw', 'estate.fn_set_digital_account'),
  ('estate_rw', 'estate.fn_set_funeral_preferences'),
  ('estate_rw', 'estate.fn_set_person_record'),
  ('estate_rw', 'estate.fn_set_provider_contract'),
  ('estate_rw', 'estate.fn_set_storage_place'),
  ('estate_rw', 'estate.fn_set_system_profile'),
  ('finance_ro', 'core.fn_config_get'),
  ('finance_ro', 'core.fn_onboarding_status'),
  ('finance_ro', 'core.fn_package_active'),
  ('finance_ro', 'core.fn_ui_texts_for'),
  ('finance_ro', 'finance.fn_account_label'),
  ('finance_ro', 'finance.fn_bank_export_account_profile'),
  ('finance_ro', 'finance.fn_fx_rate_map'),
  ('finance_ro', 'finance.fn_holding_price_status'),
  ('finance_ro', 'finance.fn_pension_statements_due'),
  ('finance_ro', 'finance.fn_recurring_suggestion_counts'),
  ('finance_rw', 'core.fn_config_get'),
  ('finance_rw', 'core.fn_dry_run'),
  ('finance_rw', 'core.fn_household_persons'),
  ('finance_rw', 'core.fn_package_active'),
  ('finance_rw', 'core.fn_proactive_claim'),
  ('finance_rw', 'core.fn_resolve_date'),
  ('finance_rw', 'core.fn_resolve_person'),
  ('finance_rw', 'core.fn_set_onboarding_section'),
  ('finance_rw', 'core.fn_today'),
  ('finance_rw', 'core.fn_ui_texts_for'),
  ('finance_rw', 'finance.fn_account_interest_defaults'),
  ('finance_rw', 'finance.fn_account_label'),
  ('finance_rw', 'finance.fn_active_currencies'),
  ('finance_rw', 'finance.fn_annual_equivalent'),
  ('finance_rw', 'finance.fn_apply_bank_statement'),
  ('finance_rw', 'finance.fn_apply_price_symbol'),
  ('finance_rw', 'finance.fn_bank_end_claim'),
  ('finance_rw', 'finance.fn_bank_todo_claim'),
  ('finance_rw', 'finance.fn_book_dividend'),
  ('finance_rw', 'finance.fn_book_interest_occurrence'),
  ('finance_rw', 'finance.fn_book_loan_payment'),
  ('finance_rw', 'finance.fn_book_recurring_occurrence'),
  ('finance_rw', 'finance.fn_book_savings_goal_transfer'),
  ('finance_rw', 'finance.fn_book_savings_plan_execution'),
  ('finance_rw', 'finance.fn_book_savings_reservation'),
  ('finance_rw', 'finance.fn_book_stock_buy'),
  ('finance_rw', 'finance.fn_book_stock_sell'),
  ('finance_rw', 'finance.fn_book_transaction'),
  ('finance_rw', 'finance.fn_book_transfer'),
  ('finance_rw', 'finance.fn_cancel_handoff_task'),
  ('finance_rw', 'finance.fn_close_account'),
  ('finance_rw', 'finance.fn_close_insurance'),
  ('finance_rw', 'finance.fn_close_pension'),
  ('finance_rw', 'finance.fn_close_savings_goal'),
  ('finance_rw', 'finance.fn_close_savings_plan'),
  ('finance_rw', 'finance.fn_create_account'),
  ('finance_rw', 'finance.fn_create_insurance'),
  ('finance_rw', 'finance.fn_create_loan'),
  ('finance_rw', 'finance.fn_create_pension'),
  ('finance_rw', 'finance.fn_create_real_estate'),
  ('finance_rw', 'finance.fn_create_recurring_payment'),
  ('finance_rw', 'finance.fn_create_recurring_transfer'),
  ('finance_rw', 'finance.fn_create_savings_goal'),
  ('finance_rw', 'finance.fn_create_savings_plan'),
  ('finance_rw', 'finance.fn_delete_account'),
  ('finance_rw', 'finance.fn_delete_holding'),
  ('finance_rw', 'finance.fn_delete_loan'),
  ('finance_rw', 'finance.fn_delete_real_estate'),
  ('finance_rw', 'finance.fn_delete_recurring_payment'),
  ('finance_rw', 'finance.fn_enum_reason'),
  ('finance_rw', 'finance.fn_feed_refresh_due'),
  ('finance_rw', 'finance.fn_feed_symbol'),
  ('finance_rw', 'finance.fn_find_holding'),
  ('finance_rw', 'finance.fn_fx_rate_map'),
  ('finance_rw', 'finance.fn_fx_rate_status'),
  ('finance_rw', 'finance.fn_get_account_close_blockers'),
  ('finance_rw', 'finance.fn_get_balance_as_of'),
  ('finance_rw', 'finance.fn_get_loan_payment_split'),
  ('finance_rw', 'finance.fn_goal_earmark_account_types'),
  ('finance_rw', 'finance.fn_goal_pot_account_types'),
  ('finance_rw', 'finance.fn_holding_price_status'),
  ('finance_rw', 'finance.fn_import_balance_targets'),
  ('finance_rw', 'finance.fn_import_bundle'),
  ('finance_rw', 'finance.fn_import_card_rows'),
  ('finance_rw', 'finance.fn_import_depot_currency'),
  ('finance_rw', 'finance.fn_import_stage'),
  ('finance_rw', 'finance.fn_import_stage_recurring'),
  ('finance_rw', 'finance.fn_import_sweep'),
  ('finance_rw', 'finance.fn_import_update_row'),
  ('finance_rw', 'finance.fn_insurance_fields'),
  ('finance_rw', 'finance.fn_interest_amount_due'),
  ('finance_rw', 'finance.fn_interest_due_open'),
  ('finance_rw', 'finance.fn_interest_rate_preview'),
  ('finance_rw', 'finance.fn_parse_numeric_or_null'),
  ('finance_rw', 'finance.fn_price_gap_claim'),
  ('finance_rw', 'finance.fn_price_gaps'),
  ('finance_rw', 'finance.fn_reconcile_account'),
  ('finance_rw', 'finance.fn_reconcile_accounts'),
  ('finance_rw', 'finance.fn_reconcile_accounts_preview'),
  ('finance_rw', 'finance.fn_reconcile_blocker'),
  ('finance_rw', 'finance.fn_reconcile_open_due'),
  ('finance_rw', 'finance.fn_record_networth_snapshot'),
  ('finance_rw', 'finance.fn_recurring_current'),
  ('finance_rw', 'finance.fn_recurring_due_open'),
  ('finance_rw', 'finance.fn_recurring_lineage'),
  ('finance_rw', 'finance.fn_replace_holding_lots'),
  ('finance_rw', 'finance.fn_replace_takeover_with_lots'),
  ('finance_rw', 'finance.fn_resolve_account'),
  ('finance_rw', 'finance.fn_resolve_insurance'),
  ('finance_rw', 'finance.fn_resolve_loan'),
  ('finance_rw', 'finance.fn_resolve_pension'),
  ('finance_rw', 'finance.fn_resolve_real_estate'),
  ('finance_rw', 'finance.fn_resolve_recurring_payment'),
  ('finance_rw', 'finance.fn_resolve_savings_goal'),
  ('finance_rw', 'finance.fn_savings_plan_next_execution'),
  ('finance_rw', 'finance.fn_sell_real_estate'),
  ('finance_rw', 'finance.fn_set_account'),
  ('finance_rw', 'finance.fn_set_account_interest'),
  ('finance_rw', 'finance.fn_set_asset_classes'),
  ('finance_rw', 'finance.fn_set_holding'),
  ('finance_rw', 'finance.fn_set_insurance'),
  ('finance_rw', 'finance.fn_set_loan'),
  ('finance_rw', 'finance.fn_set_pension'),
  ('finance_rw', 'finance.fn_set_real_estate'),
  ('finance_rw', 'finance.fn_set_recurring_payment'),
  ('finance_rw', 'finance.fn_set_savings_goal'),
  ('finance_rw', 'finance.fn_set_savings_plan'),
  ('finance_rw', 'finance.fn_settle_loan'),
  ('finance_rw', 'finance.fn_setup_advance'),
  ('finance_rw', 'finance.fn_setup_begin'),
  ('finance_rw', 'finance.fn_setup_next'),
  ('finance_rw', 'finance.fn_setup_reanchor'),
  ('finance_rw', 'finance.fn_skip_interest_occurrence'),
  ('finance_rw', 'finance.fn_statement_prepare'),
  ('finance_rw', 'finance.fn_unit_price_from_total'),
  ('finance_rw', 'finance.fn_upsert_fx_rates'),
  ('finance_rw', 'finance.fn_upsert_market_prices'),
  ('finance_rw', 'finance.fn_void_bank_statement'),
  ('finance_rw', 'finance.fn_void_transaction'),
  ('paperless_ro', 'core.fn_config_get'),
  ('paperless_ro', 'core.fn_onboarding_status'),
  ('paperless_ro', 'core.fn_package_active'),
  ('paperless_ro', 'core.fn_ui_texts_for')
-- END GENERATED PAIRS
    ) AS t (role_name, fn_name)
  LOOP
    v_n := v_n + 1;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.role_name) THEN
      v_bad := v_bad || ('Rolle ' || r.role_name || ' existiert nicht (fuer ' || r.fn_name || ')');
      CONTINUE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
                   WHERE n.nspname = split_part(r.fn_name, '.', 1) AND p.proname = split_part(r.fn_name, '.', 2)) THEN
      v_bad := v_bad || (r.fn_name || ' existiert nicht (fuer ' || r.role_name || ')');
      CONTINUE;
    END IF;
    -- (1) Aufruf unter der Rolle, je Ueberladung mit leerem und mit NULL-Payload
    FOR f IN
      SELECT p.oid, p.proargtypes::oid[] AS types
      FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = split_part(r.fn_name, '.', 1) AND p.proname = split_part(r.fn_name, '.', 2) AND p.prokind = 'f'
    LOOP
      FOR i IN 1..2 LOOP
        SELECT coalesce(array_agg(CASE WHEN i = 1 AND format_type(t.typ, NULL) IN ('jsonb', 'json')
                                       THEN quote_literal('{}') || '::' || format_type(t.typ, NULL)
                                       ELSE 'NULL::' || format_type(t.typ, NULL) END ORDER BY t.ord), '{}')
        INTO v_args FROM unnest(f.types) WITH ORDINALITY AS t (typ, ord);
        v_call := r.fn_name || '(' || array_to_string(v_args, ', ') || ')';
        v_msg := pg_temp.rp_call(r.role_name, v_call);
        EXECUTE 'RESET ROLE';
        v_calls := v_calls + 1;
        -- Ohne package faellt fn_set_onboarding_section auf 'core' zurueck, dessen Tabelle in agent liegt: dort muss ein
        -- Paket-Schreibrecht scheitern. Der echte Weg (package gesetzt) steht in test_role_permissions.sql (6).
        IF v_msg IS NOT NULL AND NOT (r.fn_name = 'core.fn_set_onboarding_section' AND r.role_name IN ('finance_rw', 'estate_rw')
                                      AND v_msg = 'permission denied for schema agent') THEN
          v_bad := v_bad || (r.role_name || ' -> ' || v_call || ': ' || v_msg);
        END IF;
        EXIT WHEN i = 1 AND NOT EXISTS (SELECT 1 FROM unnest(f.types) AS t (typ) WHERE format_type(t.typ, NULL) IN ('jsonb', 'json'));
      END LOOP;
    END LOOP;
    -- (2) Tabellen-/Sequenzrechte im fn-Text
    -- agent.fn_resolve_sender laeuft nur fuer per_user-Pakete (career); finance und estate sind household (Voraussetzung
    -- prueft test_role_catalog_exec.sql).
    v_gaps := pg_temp.rp_table_gaps(
      r.role_name, split_part(r.fn_name, '.', 1), split_part(r.fn_name, '.', 2),
      CASE WHEN r.fn_name = 'core.fn_set_onboarding_section' AND r.role_name IN ('finance_rw', 'estate_rw')
        THEN ARRAY['agent.fn_resolve_sender'] ELSE '{}'::text[] END
    );
    IF cardinality(v_gaps) > 0 THEN
      v_bad := v_bad || (r.role_name || ' -> ' || r.fn_name || ': ' || array_to_string(v_gaps, '; '));
    END IF;
  END LOOP;
  IF v_n < 100 THEN
    RAISE EXCEPTION 'FAIL: nur % Paare im Katalog, die erzeugte Liste fehlt (role_test_lint -WriteCatalog)', v_n;
  END IF;
  IF cardinality(v_bad) > 0 THEN
    RAISE EXCEPTION 'FAIL: % Befund(e) bei % Paaren / % Aufrufen:%', cardinality(v_bad), v_n, v_calls, E'\n' || array_to_string(v_bad, E'\n');
  END IF;
  RAISE NOTICE 'PASS test_role_call_probe: % Rolle/fn-Paare, % Aufrufe unter der Rolle, ohne permission denied', v_n, v_calls;
END
$t$;

ROLLBACK;
