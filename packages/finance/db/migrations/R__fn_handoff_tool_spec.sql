-- ============================================================
-- fn_handoff_tool_spec (READ, IMMUTABLE) -- die Eingabe-Form der Werkzeuge, die eine vereinbarte Plan-Aufgabe eintragen
--   Eine Adresse fuer finance.fn_handoff_precheck (fertiger Aufruf), finance.fn_handoff_diff und finance.fn_with_handoff.
--   Je Werkzeug-Schluessel (Manifest-Name ohne tool_): kinds (Vormerkungs-Arten, wie advisors.finance.handoff_tools im
--   Manifest), type (Art der eingetragenen Sache in entered_refs), inputs (Start-Knoten-Felder des Werkzeugs ohne
--   handoff_task_id, Build-Trigger in packages/finance/build/workflows/tools/<tool>.ps1), required (Pflicht fuer einen Tipp),
--   one_of (je Liste mindestens eines), requires_if ({feld: [Pflicht, wenn feld gesetzt]}), target (Namens-Feld der
--   geaenderten Sache, nur set_*), refs ({feld: {type, account_types?}} = Namen, die das Werkzeug ueber einen fn_resolve_*
--   aufloest), state ({feld: Feld aus finance.fn_handoff_ref_state} = was der Unterschied Soll gegen Ist vergleicht).
--   Werkzeug-Eingaben sind Namen, keine Kennungen: das Werkzeug loest sie selbst auf; die Vorpruefung setzt deshalb den
--   gespeicherten Namen der eindeutig gefundenen Sache ein.
--   Drift: inputs und kinds muessen zum Start-Knoten bzw. zum Manifest passen (Pruefung im contract_lint).
--   Rueckgabe jsonb {<tool>: {...}}. Tests: tests/db/finance/test_fn_handoff_precheck.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_handoff_tool_spec()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
SELECT jsonb_build_object(
  'create_savings_goal', jsonb_build_object(
      'kinds', jsonb_build_array('savings_goal'), 'type', 'savings_goal',
      'inputs', jsonb_build_array('goal_name','goal_type','target_amount','target_date','monthly_savings_rate','account_name',
                                  'schedule_day_of_month','first_payment_date','notes','beneficiary_person','reserve_account_name',
                                  'priority','already_saved','savings_plan_name','replace_transfer','real_estate_name','kind','target_months'),
      'required', jsonb_build_array('goal_name'),
      'one_of', jsonb_build_array(jsonb_build_array('target_amount','real_estate_name','kind')),
      'requires_if', jsonb_build_object('monthly_savings_rate', jsonb_build_array('account_name'),
                                        'target_amount', jsonb_build_array('reserve_account_name')),
      'refs', jsonb_build_object(
          'account_name', jsonb_build_object('type','account','account_types', jsonb_build_array('cash','p2p')),
          'reserve_account_name', jsonb_build_object('type','account'),
          'savings_plan_name', jsonb_build_object('type','savings_plan')),
      'state', jsonb_build_object('target_amount','target_amount','target_date','target_date')),
  'set_savings_goal', jsonb_build_object(
      'kinds', jsonb_build_array('savings_goal'), 'type', 'savings_goal', 'target', 'goal_name',
      'inputs', jsonb_build_array('goal_name','new_name','target_amount','target_date','status','notes','beneficiary_person',
                                  'reserve_account_name','priority','link_savings_plan_name','unlink_savings_plan_name','stop_funders',
                                  'account_name','replace_transfer','monthly_savings_rate','kind','target_months','depot_risk_accepted'),
      'required', jsonb_build_array('goal_name'),
      'refs', jsonb_build_object(
          'goal_name', jsonb_build_object('type','savings_goal'),
          'account_name', jsonb_build_object('type','account','account_types', jsonb_build_array('cash','p2p')),
          'reserve_account_name', jsonb_build_object('type','account'),
          'link_savings_plan_name', jsonb_build_object('type','savings_plan'),
          'unlink_savings_plan_name', jsonb_build_object('type','savings_plan')),
      'state', jsonb_build_object('target_amount','target_amount','target_date','target_date','status','status')),
  'create_savings_plan', jsonb_build_object(
      'kinds', jsonb_build_array('savings_plan'), 'type', 'savings_plan',
      'inputs', jsonb_build_array('plan_name','depot_name','isin','symbol','security_name','amount','schedule_interval','schedule_unit',
                                  'schedule_day_of_month','first_payment_date','notes','beneficiary_person','asset_class','depot_execution_days'),
      'required', jsonb_build_array('plan_name','depot_name','amount','schedule_unit','first_payment_date'),
      'one_of', jsonb_build_array(jsonb_build_array('isin','security_name')),
      'refs', jsonb_build_object('depot_name', jsonb_build_object('type','account','account_types', jsonb_build_array('stocks_depot','crypto_depot'))),
      'state', jsonb_build_object('amount','amount','schedule_day_of_month','day')),
  'set_savings_plan', jsonb_build_object(
      'kinds', jsonb_build_array('savings_plan'), 'type', 'savings_plan', 'target', 'savings_plan_name',
      'inputs', jsonb_build_array('savings_plan_name','new_amount','schedule_unit','schedule_interval','status','valid_from','notes',
                                  'beneficiary_person','asset_class','depot_execution_days','valid_to'),
      'required', jsonb_build_array('savings_plan_name'),
      'refs', jsonb_build_object('savings_plan_name', jsonb_build_object('type','savings_plan')),
      'state', jsonb_build_object('new_amount','amount','valid_to','valid_to','status','status')),
  'create_recurring_payment', jsonb_build_object(
      'kinds', jsonb_build_array('recurring_payment'), 'type', 'recurring_payment',
      'inputs', jsonb_build_array('name','account_name','direction','amount','schedule_interval','schedule_unit','schedule_day_of_month',
                                  'first_payment_date','valid_from','valid_to','notes','counterparty_iban'),
      'required', jsonb_build_array('name','account_name','direction','amount','schedule_unit','first_payment_date'),
      'refs', jsonb_build_object('account_name', jsonb_build_object('type','account')),
      'state', jsonb_build_object('amount','amount','schedule_day_of_month','day','valid_to','valid_to','account_name','account')),
  'set_recurring_payment', jsonb_build_object(
      'kinds', jsonb_build_array('recurring_payment','recurring_transfer'), 'type', 'recurring_payment', 'target', 'payment_name',
      'inputs', jsonb_build_array('payment_name','new_name','amount','valid_from','status','valid_to','schedule_day_of_month','notes',
                                  'until_free_money','executed_by'),
      'required', jsonb_build_array('payment_name'),
      'refs', jsonb_build_object('payment_name', jsonb_build_object('type','recurring_payment')),
      'state', jsonb_build_object('amount','amount','schedule_day_of_month','day','valid_to','valid_to','status','status')),
  'create_recurring_transfer', jsonb_build_object(
      'kinds', jsonb_build_array('recurring_transfer'), 'type', 'recurring_payment',
      'inputs', jsonb_build_array('name','from_account_name','to_account_name','amount','schedule_interval','schedule_unit',
                                  'schedule_day_of_month','first_payment_date','valid_from','valid_to','notes','until_free_money','executed_by'),
      'required', jsonb_build_array('name','from_account_name','to_account_name','amount','schedule_unit','first_payment_date'),
      'refs', jsonb_build_object('from_account_name', jsonb_build_object('type','account'),
                                 'to_account_name', jsonb_build_object('type','account')),
      'state', jsonb_build_object('amount','amount','schedule_day_of_month','day','valid_to','valid_to',
                                  'from_account_name','account','to_account_name','to_account')),
  'create_pension', jsonb_build_object(
      'kinds', jsonb_build_array('other'), 'type', 'pension',
      'inputs', jsonb_build_array('name','pension_type','provider','contract_number','owner_person','current_value','value_updated_at',
                                  'guaranteed_monthly_pension','retirement_start_date','contribution_amount','schedule_interval',
                                  'schedule_unit','debit_account_name','schedule_day_of_month','first_payment_date','notes'),
      'required', jsonb_build_array('name','pension_type'),
      'requires_if', jsonb_build_object('contribution_amount', jsonb_build_array('debit_account_name')),
      'refs', jsonb_build_object('debit_account_name', jsonb_build_object('type','account','account_types', jsonb_build_array('cash'))),
      'state', jsonb_build_object('provider','provider','guaranteed_monthly_pension','guaranteed_monthly_pension',
                                  'contribution_amount','contribution_amount')),
  'set_pension', jsonb_build_object(
      'kinds', jsonb_build_array('other'), 'type', 'pension', 'target', 'pension_name',
      'inputs', jsonb_build_array('pension_name','new_name','provider','contract_number','owner_person','current_value','value_updated_at',
                                  'guaranteed_monthly_pension','retirement_start_date','status','notes','contribution_amount',
                                  'effective_from','schedule_interval','schedule_unit','debit_account_name'),
      'required', jsonb_build_array('pension_name'),
      'refs', jsonb_build_object('pension_name', jsonb_build_object('type','pension'),
                                 'debit_account_name', jsonb_build_object('type','account')),
      'state', jsonb_build_object('provider','provider','guaranteed_monthly_pension','guaranteed_monthly_pension',
                                  'contribution_amount','contribution_amount','status','status'))
);
$$;
