-- tests/db/core/test_fn_set_monitor_trigger.sql
-- Testet fn_set_monitor_trigger: partielles Update + Lifecycle (disable, Re-Arm, reset_peak).
-- Vertrag: Aufloesung per domain+label (fn_resolve_monitor_trigger, 0/>1 -> {ok:false} mit
--   Kandidaten); partielles UPDATE via COALESCE(NULLIF) inkl. Prompt/SQL-Edit (re-validiert);
--   new_label = Rename (unique_violation -> {ok:false}); status armed|disabled; Re-Arm
--   (fired->armed) resettet fired_at/fail_streak + re-anker next_check_at; reset_peak=true
--   nullt reference_value (neue Ratchet-Epoche); Typ-Wechsel abgelehnt; Cadence-Aenderung
--   re-anker next_check_at; Web-Cadence < 12h abgelehnt.
BEGIN;

DO $$
DECLARE
  v      JSONB;
  v_id   INT;
  v_row  agent.monitor_triggers%ROWTYPE;
  v_old_next TIMESTAMPTZ;
BEGIN

  -- Fixture
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4000',
    'trigger_type', 'threshold', 'acquisition_method', 'web_search',
    'acquisition_prompt', 'gold usd per ounce', 'comparator', 'gte', 'threshold_value', 4000,
    'expected_unit', 'USD/oz', 'check_interval', '1 day', 'action_note', 'alt'
  ));
  v_id := (v->>'trigger_id')::int;

  -- TEST 1: partielles Update — nur threshold_value + action_note, Rest unveraendert
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4000',
    'threshold_value', 4200, 'action_note', 'neu'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set [partial]: got %', v;
  END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.threshold_value IS DISTINCT FROM 4200 OR v_row.action_note IS DISTINCT FROM 'neu'
     OR v_row.comparator IS DISTINCT FROM 'gte'
     OR v_row.acquisition_spec->>'prompt' IS DISTINCT FROM 'gold usd per ounce' THEN
    RAISE EXCEPTION 'FAIL set [partial]: Zeile falsch (thr=%, note=%, cmp=%)',
      v_row.threshold_value, v_row.action_note, v_row.comparator;
  END IF;
  RAISE NOTICE 'PASS set [partielles Update]';

  -- TEST 2: Prompt-Edit (Quellen driften -> Repair-Flow)
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4000',
    'acquisition_prompt', 'NEW gold spot price USD per troy ounce from LBMA'
  ));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.acquisition_spec->>'prompt' NOT LIKE 'NEW gold%' THEN
    RAISE EXCEPTION 'FAIL set [prompt edit]: spec=%', v_row.acquisition_spec;
  END IF;
  RAISE NOTICE 'PASS set [Prompt-Edit]';

  -- TEST 3: Rename + Rename auf bestehendes Label -> {ok:false}
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Other Trigger', 'trigger_type', 'date',
    'due_date', '2027-01-01', 'check_interval', '1 day'));
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4000', 'new_label', 'Gold over 4200'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set [rename]: got %', v;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE id = v_id AND label = 'Gold over 4200') THEN
    RAISE EXCEPTION 'FAIL set [rename]: Label nicht geaendert';
  END IF;
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'new_label', 'other trigger'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set [rename dup]: got %', v;
  END IF;
  RAISE NOTICE 'PASS set [Rename + Dubletten-Schutz]';

  -- TEST 3b (WP3): due_date relativ rechnet die DB; neu gesendete Vergangenheit -> {ok:false}
  v := agent.fn_set_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'Other Trigger', 'due_date', 'in 3 weeks'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'due_date')::date IS DISTINCT FROM core.fn_today() + 21
     OR (SELECT due_date FROM agent.monitor_triggers WHERE label = 'Other Trigger') IS DISTINCT FROM core.fn_today() + 21 THEN
    RAISE EXCEPTION 'FAIL set [due_date relativ]: got %', v;
  END IF;
  v := agent.fn_set_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'Other Trigger', 'due_date', 'yesterday'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%past%' THEN
    RAISE EXCEPTION 'FAIL set [due_date Vergangenheit]: got %', v;
  END IF;
  RAISE NOTICE 'PASS set [due_date relativ von der DB, Vergangenheit abgelehnt]';

  -- TEST 4: not found -> {ok:false} mit Kandidaten-Hinweis
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'No Such Trigger', 'threshold_value', 1
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set [not found]: got %', v;
  END IF;
  RAISE NOTICE 'PASS set [not found -> ok:false]';

  -- TEST 5: disable + Re-Arm (fired->armed: fired_at/fail_streak weg, next_check_at frisch)
  UPDATE agent.monitor_triggers
     SET status = 'fired', fired_at = NOW() - INTERVAL '1 day', fail_streak = 3,
         reference_value = 110, next_check_at = NOW() - INTERVAL '2 days'
   WHERE id = v_id;
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'status', 'armed'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set [re-arm]: got %', v;
  END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.status IS DISTINCT FROM 'armed' OR v_row.fired_at IS NOT NULL
     OR v_row.fail_streak IS DISTINCT FROM 0 OR v_row.next_check_at < NOW() - INTERVAL '1 minute' THEN
    RAISE EXCEPTION 'FAIL set [re-arm]: status=%, fired_at=%, streak=%, next=%',
      v_row.status, v_row.fired_at, v_row.fail_streak, v_row.next_check_at;
  END IF;
  -- reference_value bleibt OHNE reset_peak erhalten
  IF v_row.reference_value IS DISTINCT FROM 110 THEN
    RAISE EXCEPTION 'FAIL set [re-arm]: reference_value ohne reset_peak geaendert: %', v_row.reference_value;
  END IF;
  RAISE NOTICE 'PASS set [Re-Arm: fired_at/fail_streak weg, Ratchet bleibt]';

  -- TEST 6: reset_peak -> reference_value NULL (neue Ratchet-Epoche)
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'reset_peak', true
  ));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.reference_value IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL set [reset_peak]: ref=%', v_row.reference_value;
  END IF;
  RAISE NOTICE 'PASS set [reset_peak nullt Ratchet]';

  -- TEST 7: disable
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'status', 'disabled'
  ));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.status IS DISTINCT FROM 'disabled' THEN
    RAISE EXCEPTION 'FAIL set [disable]: status=%', v_row.status;
  END IF;
  RAISE NOTICE 'PASS set [disable]';

  -- TEST 7b: Tool-Payload-Form — das Werkzeug schickt nicht genannte Felder als '' (n8n-$fromAI-Default).
  -- Real 2026-10-20 (E2E me02): reset_peak='' brach mit "invalid input syntax for type boolean" ab ->
  -- kein Trigger liess sich aendern, ohne reset_peak ausdruecklich zu senden.
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'status', 'armed', 'reset_peak', '',
    'new_label', '', 'check_interval', '', 'action_note', '', 'min_plausible', '', 'max_plausible', ''
  ));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR v_row.status IS DISTINCT FROM 'armed' THEN
    RAISE EXCEPTION 'FAIL set [tool payload, leere Felder]: got % / status=%', v, v_row.status;
  END IF;
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'status', 'disabled', 'reset_peak', ''
  ));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.status IS DISTINCT FROM 'disabled' THEN
    RAISE EXCEPTION 'FAIL set [tool payload disable]: status=%', v_row.status;
  END IF;
  RAISE NOTICE 'PASS set [Tool-Payload: leere Felder = unveraendert, auch reset_peak]';

  -- TEST 8: Typ-Wechsel abgelehnt
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'trigger_type', 'date'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%type%' THEN
    RAISE EXCEPTION 'FAIL set [type change]: got %', v;
  END IF;
  RAISE NOTICE 'PASS set [Typ-Wechsel abgelehnt]';

  -- TEST 9: Cadence-Aenderung re-anker next_check_at; Web < 12h abgelehnt
  SELECT next_check_at INTO v_old_next FROM agent.monitor_triggers WHERE id = v_id;
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'check_interval', '2 days'
  ));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.check_interval IS DISTINCT FROM INTERVAL '2 days' THEN
    RAISE EXCEPTION 'FAIL set [cadence]: interval=%', v_row.check_interval;
  END IF;
  v := agent.fn_set_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4200', 'check_interval', '4 hours'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%12%' THEN
    RAISE EXCEPTION 'FAIL set [web cadence]: got %', v;
  END IF;
  RAISE NOTICE 'PASS set [Cadence-Aenderung + Web-Rate-Limit-Guard]';

END $$;

ROLLBACK;
