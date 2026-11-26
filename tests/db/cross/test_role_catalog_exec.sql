-- tests/db/cross/test_role_catalog_exec.sql
-- Katalog-Rechtepruefung: jede fn, die ein gebauter Workflow unter einer engen Rolle aufruft, ist fuer genau diese Rolle
-- ausfuehrbar (Schema-USAGE + EXECUTE), samt aller Helfer, die sie als INVOKER weiter aufruft (schema.fn_x( und
-- unqualifiziertes fn_x( im eigenen Schema; eine DEFINER-fn laeuft mit Eigentuemer-Rechten und beendet die Kette).
-- db_test laeuft als Superuser und sieht ein vergessenes GRANT nie; ein echter SET-LOCAL-ROLE-Aufruf je fn steht in
-- test_role_permissions.sql (nur wo vorhanden). Die Paar-Liste erzeugt scripts/role_test_lint.ps1 -WriteCatalog aus den
-- Workflows, der Lint haelt sie aktuell. Grenze: nur Ausfuehrungsrechte, keine Tabellen-/Sequenzrechte im Koerper.
BEGIN;

CREATE FUNCTION pg_temp.rc_missing(p_role text, p_schema text, p_fn text, p_skip text[] DEFAULT '{}') RETURNS text[]
LANGUAGE plpgsql AS $f$
DECLARE
  v_out   text[] := '{}';
  v_queue text[] := ARRAY[p_schema || '.' || p_fn];
  v_seen  text[] := '{}';
  v_cur   text;
  v_schema text;
  v_name  text;
  v_found boolean;
  r       record;
  h       record;
  v_src   text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
    RETURN ARRAY['Rolle ' || p_role || ' existiert nicht'];
  END IF;
  WHILE coalesce(array_length(v_queue, 1), 0) > 0 LOOP
    v_cur := v_queue[1];
    v_queue := v_queue[2:array_length(v_queue, 1)];
    CONTINUE WHEN v_cur = ANY (v_seen);
    v_seen := v_seen || v_cur;
    v_schema := split_part(v_cur, '.', 1);
    v_name := split_part(v_cur, '.', 2);
    v_found := false;
    FOR r IN
      SELECT p.oid, p.prosecdef, p.prosrc
      FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema AND p.proname = v_name
    LOOP
      v_found := true;
      IF NOT has_schema_privilege(p_role, v_schema, 'USAGE') THEN
        v_out := v_out || (p_role || ' hat kein USAGE auf Schema ' || v_schema || ' (fuer ' || v_cur || ')');
      END IF;
      IF NOT has_function_privilege(p_role, r.oid, 'EXECUTE') THEN
        v_out := v_out || (p_role || ' darf ' || r.oid::regprocedure::text || ' nicht ausfuehren');
      END IF;
      IF NOT r.prosecdef THEN
        v_src := regexp_replace(
          regexp_replace(regexp_replace(r.prosrc, '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g'),
          '''[^'']*''', '', 'g'
        );
        FOR h IN
          SELECT DISTINCT m[1] || '.' || m[2] AS q
          FROM regexp_matches(v_src, '\m([a-z][a-z0-9_]*)\.(fn_[a-z0-9_]+)\s*\(', 'g') AS m
          UNION
          SELECT DISTINCT v_schema || '.' || m[1] AS q
          FROM regexp_matches(v_src, '(?<![.\w])(fn_[a-z0-9_]+)\s*\(', 'g') AS m
          WHERE EXISTS (
            SELECT 1 FROM pg_proc AS p2 JOIN pg_namespace AS n2 ON n2.oid = p2.pronamespace
            WHERE n2.nspname = v_schema AND p2.proname = m[1]
          )
        LOOP
          IF h.q <> v_cur AND NOT (h.q = ANY (p_skip)) THEN v_queue := v_queue || h.q; END IF;
        END LOOP;
      END IF;
    END LOOP;
    IF NOT v_found AND v_cur = p_schema || '.' || p_fn THEN
      v_out := v_out || (v_cur || ' existiert nicht');
    END IF;
  END LOOP;
  RETURN v_out;
END
$f$;

-- Selbsttest: ein gesperrter Helfer hinter einer INVOKER-fn wird gefunden, nach dem Grant nicht mehr.
CREATE FUNCTION core.fn_rc_probe_inner() RETURNS int LANGUAGE sql AS 'SELECT 1';
REVOKE ALL ON FUNCTION core.fn_rc_probe_inner() FROM public;
CREATE FUNCTION finance.fn_rc_probe_outer() RETURNS int LANGUAGE plpgsql AS $p$ BEGIN RETURN core.fn_rc_probe_inner(); END $p$;
GRANT EXECUTE ON FUNCTION finance.fn_rc_probe_outer() TO finance_rw;

DO $t$
DECLARE
  v_m text[];
BEGIN
  v_m := pg_temp.rc_missing('finance_rw', 'finance', 'fn_rc_probe_outer');
  IF NOT (array_to_string(v_m, ' | ') ~ 'fn_rc_probe_inner') THEN
    RAISE EXCEPTION 'FAIL: gesperrter Helfer hinter INVOKER-fn nicht erkannt: %', v_m;
  END IF;
  GRANT EXECUTE ON FUNCTION core.fn_rc_probe_inner() TO finance_rw;
  v_m := pg_temp.rc_missing('finance_rw', 'finance', 'fn_rc_probe_outer');
  IF cardinality(v_m) <> 0 THEN
    RAISE EXCEPTION 'FAIL: Helfer nach dem Grant weiter gemeldet: %', v_m;
  END IF;
  v_m := pg_temp.rc_missing('finance_rw', 'finance', 'fn_rc_gibt_es_nicht');
  IF cardinality(v_m) = 0 THEN
    RAISE EXCEPTION 'FAIL: fehlende fn nicht gemeldet';
  END IF;
  v_m := pg_temp.rc_missing('rolle_gibt_es_nicht', 'finance', 'fn_rc_probe_outer');
  IF cardinality(v_m) = 0 THEN
    RAISE EXCEPTION 'FAIL: fehlende Rolle nicht gemeldet';
  END IF;
END
$t$;

DO $t$
DECLARE
  r     record;
  v_m   text[];
  v_bad text[] := '{}';
  v_n   int := 0;
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
  ('finance_ro', 'finance.fn_bank_export_facts'),
  ('finance_ro', 'finance.fn_fx_rate_map'),
  ('finance_ro', 'finance.fn_holding_price_status'),
  ('finance_ro', 'finance.fn_pension_statements_due'),
  ('finance_ro', 'finance.fn_recurring_suggestion_counts'),
  ('finance_ro', 'finance.fn_statements_due'),
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
  ('finance_rw', 'finance.fn_defer_handoff_task'),
  ('finance_rw', 'finance.fn_delete_account'),
  ('finance_rw', 'finance.fn_delete_holding'),
  ('finance_rw', 'finance.fn_delete_loan'),
  ('finance_rw', 'finance.fn_delete_real_estate'),
  ('finance_rw', 'finance.fn_delete_recurring_payment'),
  ('finance_rw', 'finance.fn_enum_reason'),
  ('finance_rw', 'finance.fn_feed_down_claim'),
  ('finance_rw', 'finance.fn_feed_refresh_due'),
  ('finance_rw', 'finance.fn_feed_symbol'),
  ('finance_rw', 'finance.fn_find_holding'),
  ('finance_rw', 'finance.fn_fx_feed_gap'),
  ('finance_rw', 'finance.fn_fx_history_due'),
  ('finance_rw', 'finance.fn_fx_metal_due'),
  ('finance_rw', 'finance.fn_fx_rate_map'),
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
    -- core.fn_set_onboarding_section ruft agent.fn_resolve_sender nur fuer per_user-Pakete (career); finance und estate
    -- sind household, der Zweig laeuft dort nie. Die Voraussetzung prueft der Block darunter.
    v_m := pg_temp.rc_missing(
      r.role_name, split_part(r.fn_name, '.', 1), split_part(r.fn_name, '.', 2),
      CASE WHEN r.fn_name = 'core.fn_set_onboarding_section' AND r.role_name IN ('finance_rw', 'estate_rw')
        THEN ARRAY['agent.fn_resolve_sender'] ELSE '{}'::text[] END
    );
    IF cardinality(v_m) > 0 THEN
      v_bad := v_bad || (r.role_name || ' -> ' || r.fn_name || ': ' || array_to_string(v_m, '; '));
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM core.context_scopes WHERE package IN ('finance', 'estate') AND scope = 'per_user') THEN
    RAISE EXCEPTION 'FAIL: finance/estate haben einen per_user-Scope, die Ausnahme fuer agent.fn_resolve_sender ist nicht mehr gueltig';
  END IF;
  IF v_n < 100 THEN
    RAISE EXCEPTION 'FAIL: nur % Paare im Katalog, die erzeugte Liste fehlt (role_test_lint -WriteCatalog)', v_n;
  END IF;
  IF cardinality(v_bad) > 0 THEN
    RAISE EXCEPTION 'FAIL: % von % Aufrufen scheitern unter ihrer Rolle an fehlenden Rechten:%', cardinality(v_bad), v_n, E'\n' || array_to_string(v_bad, E'\n');
  END IF;
  RAISE NOTICE 'PASS test_role_catalog_exec: % Rolle/fn-Paare ausfuehrbar', v_n;
END
$t$;

ROLLBACK;
