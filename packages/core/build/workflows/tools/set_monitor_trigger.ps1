#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_set_monitor_trigger (CROSS-AGENT, HITL-Write) ----------------
# Aendert EINEN bestehenden Monitor-Trigger (partielles UPDATE: nicht gesendet = unveraendert)
# inkl. Lifecycle: status armed (RE-ARM eines gefeuerten Triggers) | disabled, reset_peak
# (Drawdown-Ratchet nullen), Prompt-/SQL-Edit (Repair-Flow — Quellen driften).
# Binder: NUR agent.monitor (der Advisor verweist Edits/Repair an den Monitor-Agenten).
# RE-PROBE bei Spec-Aenderung: wird Prompt/SQL/Methoden-Parameter (acquisition_params, Paket-Methode) geaendert,
# laeuft die Beschaffung einmal exakt wie der Cron VOR dem Gate (Probe-Fail = ToolError, nichts geschrieben).
# Die Probe bekommt die ueber die gespeicherte Spec gemergten Parameter; der Write sendet nur die geaenderten Keys
# (fn_set_monitor_trigger merged + laesst die validate_fn des Pakets pruefen).
function Build-SetMonitorTrigger {
    $trig = Build-Trigger @(
        'domain', 'label', 'new_label',
        'acquisition_prompt', 'acquisition_sql', 'acquisition_params',
        'comparator', 'threshold_value', 'drawdown_pct',
        'due_date', 'warn_days_before',
        'expected_unit', 'min_plausible', 'max_plausible', 'max_jump_pct',
        'check_interval', 'action_note', 'status', 'reset_peak'
    )

    $resolveDomain = Build-Set 'Resolve domain' @(180, 0) @(
        ,@('domain', '={{ String($(''Start'').item.json.chat_id || '''').startsWith(''test_e2e'') ? ''__e2e_monitor__'' : ($(''Start'').item.json.domain || ''general'') }}', 'string')
    )

    # Resolve + aktuelle Trigger-Config (fuer Probe-Entscheidung + Validierungs-Defaults)
    $resolve = Build-Pg 'Resolve trigger' @(360, 0) `
        "=SELECT r.id, r.hit_count, r.candidates::text AS candidates, t.trigger_type, t.acquisition_method, t.acquisition_spec::text AS spec, t.expected_unit AS cur_unit, t.min_plausible AS cur_min, t.max_plausible AS cur_max, t.max_jump_pct AS cur_jump, t.last_value AS cur_last, t.status AS cur_status FROM agent.fn_resolve_monitor_trigger((`$1::jsonb)->>'label', (`$1::jsonb)->>'domain', false) AS r LEFT JOIN agent.monitor_triggers t ON t.id = r.id;" `
        ([ordered]@{
            label  = '$(''Start'').item.json.label'
            domain = '$(''Resolve domain'').item.json.domain'
        })
    $ifFound = Build-If 'Found?' @(540, 0) '={{ $json.hit_count }}' '1' 'equals' 'number'
    $errFound = Build-ToolError 'Not found' @(720, -200) `
        "={{ `$('Resolve trigger').item.json.hit_count === 0 ? 'No trigger with this label in this domain. List existing triggers via postgres_select on agent.monitor_triggers and ask the user.' : 'Label is ambiguous across domains - specify the domain. Candidates: ' + `$('Resolve trigger').item.json.candidates }}"

    # Spec geaendert? (je Methode das passende Feld) -> Re-Probe; sonst direkt zur Summary.
    $ifSpec = Build-If 'Spec changed?' @(720, 0) `
        "={{ (`$('Resolve trigger').item.json.acquisition_method === 'web_search' ? (`$('Start').item.json.acquisition_prompt || '') : `$('Resolve trigger').item.json.acquisition_method === 'sql' ? (`$('Start').item.json.acquisition_sql || '') : `$('Resolve trigger').item.json.acquisition_method === 'none' ? '' : String(`$('Start').item.json.acquisition_params || '')).trim().length }}" `
        '0' 'larger' 'number'

    # Paket-Methode: neue Keys geschuetzt parsen (kaputtes JSON -> Sentinel -> fn {ok:false}); fuer die Probe ueber die
    # gespeicherte Spec mergen (nur ein Objekt wird gemergt — der Sentinel-String geht unveraendert durch).
    $newParamsExpr = Get-GuardedJsonExpr '$(''Start'').item.json.acquisition_params ? JSON.parse($(''Start'').item.json.acquisition_params) : null'
    $probeParamsExpr = "(x => (x && typeof x === 'object') ? Object.assign({}, JSON.parse(`$('Resolve trigger').item.json.spec || '{}'), x) : x)($newParamsExpr)"

    $ifWeb = Build-If 'Web probe?' @(900, -80) `
        "={{ `$('Resolve trigger').item.json.acquisition_method }}" 'web_search' 'equals' 'string'
    $loadModel = New-MonitorModelConfigNode -Pos @(990, -340)
    $acquire = New-MonitorAcquireHttpNode 'Acquire web value' @(1080, -200) "`$('Start').item.json.acquisition_prompt"
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = (Get-MonitorShapeJs 'return [{ json: { probe: obs } }];') }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(1260, -200)
        id = (New-Id)
        name = 'Shape probe observation'
    }

    # Validierungs-Defaults: neue Werte, sonst aktuelle Trigger-Config (Jump-Guard prueft
    # die NEUE Quelle gegen den letzten sauberen Wert — faengt Skalen-/Quellenwechsel).
    $probe = Build-Pg 'Probe (validate)' @(1440, -80) `
        "=SELECT (r->>'ok')::boolean AS probe_ok, (r->>'value')::numeric AS probe_value, r->>'unit' AS probe_unit, r->>'as_of' AS probe_as_of, r->>'source_url' AS probe_source, r->>'reason' AS probe_reason, r->'display' AS probe_display FROM agent.fn_monitor_probe(`$1::jsonb) AS r;" `
        ([ordered]@{
            acquisition_method = '$(''Resolve trigger'').item.json.acquisition_method'
            acquisition_sql    = '$(''Start'').item.json.acquisition_sql'
            acquisition_params = $probeParamsExpr
            expected_unit      = '($(''Start'').item.json.expected_unit || $(''Resolve trigger'').item.json.cur_unit || '''')'
            min_plausible      = '($(''Start'').item.json.min_plausible || $(''Resolve trigger'').item.json.cur_min || '''')'
            max_plausible      = '($(''Start'').item.json.max_plausible || $(''Resolve trigger'').item.json.cur_max || '''')'
            max_jump_pct       = '($(''Start'').item.json.max_jump_pct || $(''Resolve trigger'').item.json.cur_jump || '''')'
            last_value         = '($(''Resolve trigger'').item.json.cur_last || '''')'
            observation        = '($json.probe || null)'
        })
    $ifProbeOk = Build-If 'Probe ok?' @(1620, -80) '={{ $json.probe_ok }}' 'true' 'equals' 'boolean'
    $errProbe = Build-ToolError 'Probe failed' @(1800, -280) `
        "={{ 'Test acquisition with the NEW spec failed BEFORE approval - nothing was changed. Reason: ' + (`$('Probe (validate)').item.json.probe_reason || 'unknown') + '. Refine the acquisition with the user and retry.' }}"

    # Summary: nur GEAENDERTE Felder (nicht gesendete bleiben unveraendert) + Probe-Ergebnis.
    # Strukturiertes Summary (Textkatalog; nur genannte Felder -> -LinesExpr). probe_display = Bestaetigungszeile (tpl-Objekt oder String)
    # der Paket-validate_fn (kind raw); der Probe-Knoten laeuft nur bei geaenderter Quelle (try/catch).
    $linesExpr = @'
(() => {
  const s = $('Start').item.json;
  const r = $('Resolve trigger').item.json;
  let p = null;
  try { p = $('Probe (validate)').item.json; } catch (e) { p = null; }
  const cut = (x) => { const v = String(x || ''); return v.slice(0, 200) + (v.length > 200 ? '…' : ''); };
  const unit = (u) => (u ? ' ' + u : '');
  const L = [];
  L.push({ label: 'core.label.trigger', kind: 'tpl', value: 'core.tpl.monitor_trigger_ref',
    params: { label: s.label, domain: $('Resolve domain').item.json.domain,
              status: { kind: 'enum', enum: 'core.enum.trigger_status', value: r.cur_status } } });
  const add = (cond, line) => { if (cond) L.push(line); };
  add(s.new_label, { label: 'core.label.new_label', kind: 'text', value: s.new_label });
  add(s.comparator, { label: 'core.label.comparison', kind: 'text', value: (s.comparator === 'lte' ? '<=' : '>=') });
  add(s.threshold_value, { label: 'core.label.new_threshold', kind: 'text', value: s.threshold_value });
  add(s.drawdown_pct, { label: 'core.label.new_drawdown', kind: 'tpl', value: 'core.tpl.percent', params: { pct: s.drawdown_pct } });
  add(s.due_date, { label: 'core.label.new_due', kind: 'date', value: s.due_date });
  add(s.warn_days_before, { label: 'core.label.warn_before', kind: 'tpl', value: 'core.tpl.days', params: { days: s.warn_days_before } });
  add(s.check_interval, { label: 'core.label.new_check_interval', kind: 'tpl', value: 'core.tpl.monitor_every', params: { interval: s.check_interval } });
  add(s.expected_unit, { label: 'core.label.unit', kind: 'text', value: s.expected_unit });
  add(s.min_plausible || s.max_plausible, { label: 'core.label.plausible', kind: 'tpl', value: 'core.tpl.range',
    params: { min: s.min_plausible || '-', max: s.max_plausible || '-' } });
  add(s.max_jump_pct, { label: 'core.label.jump_guard', kind: 'tpl', value: 'core.tpl.monitor_jump_max', params: { pct: s.max_jump_pct } });
  add(s.action_note, { label: 'core.label.action_on_fire', kind: 'text', value: s.action_note });
  add(s.acquisition_prompt, { label: 'core.label.new_prompt_start', kind: 'text', value: '"' + cut(s.acquisition_prompt) + '"' });
  add(s.acquisition_sql, { label: 'core.label.new_sql_start', kind: 'text', value: cut(s.acquisition_sql) });
  if (p && p.probe_display) L.push({ kind: 'raw', value: p.probe_display });
  if (s.status === 'armed' && r.cur_status === 'fired') L.push({ label: 'core.label.rearm', kind: 'bool', value: true });
  else add(s.status, { label: 'core.label.status', kind: 'enum', enum: 'core.enum.trigger_status_change', value: s.status });
  add(String(s.reset_peak) === 'true', { label: 'core.label.reset_peak', kind: 'bool', value: true });
  if (p) {
    const has = p.probe_value !== null && p.probe_value !== undefined;
    L.push(!has ? { label: 'core.label.probe_new_source', kind: 'text', value: '' }
      : (p.probe_source
        ? { label: 'core.label.probe_new_source', kind: 'tpl', value: (p.probe_as_of ? 'core.tpl.monitor_probe_source_asof' : 'core.tpl.monitor_probe_source'),
            params: { value: p.probe_value, unit: unit(p.probe_unit), source: p.probe_source, asof: p.probe_as_of || '' } }
        : { label: 'core.label.probe_new_source', kind: 'text', value: String(p.probe_value) + unit(p.probe_unit) }));
  }
  L.push({ kind: 'note', value: 'core.note.unchanged_fields' });
  return L;
})()
'@
    $summary = New-HitlSummary -Pos @(1800, 0) -Title 'core.hitl.set_monitor_trigger' -LinesExpr $linesExpr.Trim()

    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(2160, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2340, 200) 'the set_monitor_trigger action'

    $set = Build-Pg 'Set trigger (atomic)' @(2340, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'trigger_id')::int AS trigger_id, r->>'status' AS status, r->>'next_check_at' AS next_check_at, r->>'check_interval' AS check_interval, (r->>'reference_value')::numeric AS reference_value FROM agent.fn_set_monitor_trigger(`$1::jsonb) AS r;" `
        ([ordered]@{
            domain             = '$(''Resolve domain'').item.json.domain'
            label              = '$(''Start'').item.json.label'
            new_label          = '$(''Start'').item.json.new_label'
            acquisition_prompt = '$(''Start'').item.json.acquisition_prompt'
            acquisition_sql    = '$(''Start'').item.json.acquisition_sql'
            acquisition_params = $newParamsExpr
            comparator         = '$(''Start'').item.json.comparator'
            threshold_value    = '$(''Start'').item.json.threshold_value'
            drawdown_pct       = '$(''Start'').item.json.drawdown_pct'
            due_date           = '$(''Start'').item.json.due_date'
            warn_days_before   = '$(''Start'').item.json.warn_days_before'
            expected_unit      = '$(''Start'').item.json.expected_unit'
            min_plausible      = '$(''Start'').item.json.min_plausible'
            max_plausible      = '$(''Start'').item.json.max_plausible'
            max_jump_pct       = '$(''Start'').item.json.max_jump_pct'
            check_interval     = '$(''Start'').item.json.check_interval'
            action_note        = '$(''Start'').item.json.action_note'
            status             = '$(''Start'').item.json.status'
            reset_peak         = '$(''Start'').item.json.reset_peak'
        })

    $ifOk = Build-If 'Write ok?' @(2520, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2700, 200) "={{ `$('Set trigger (atomic)').item.json.reason }}"

    $ret = Build-Return @(2700, 0) @(
        ,@('ok','true','boolean')
        ,@('trigger_id', '={{ $json.trigger_id }}', 'number')
        ,@('status', '={{ $json.status }}', 'string')
        ,@('next_check_at', '={{ $json.next_check_at }}', 'string')
        ,@('check_interval', '={{ $json.check_interval }}', 'string')
        ,@('reference_value', '={{ $json.reference_value }}', 'number')
    )

    $sticky = Build-Sticky 'Doc Set Trigger' @(120, -460) `
        'Re-Probe bei Spec-Änderung + agent.fn_set_monitor_trigger (atomar)' `
        'Nur agent.monitor bindet dieses Tool (Advisor verweist Edits/Repair hierher). Partielles UPDATE (COALESCE/NULLIF in der fn: nicht gesendet = unverändert). Lifecycle: status=armed auf fired = RE-ARM (fired_at/fail_streak weg, next_check_at frisch); disabled = parken; reset_peak nullt den Drawdown-Ratchet (neue Epoche). REPAIR-FLOW: neuer Prompt/SQL/Methoden-Parameter (acquisition_params einer Paket-Methode, über die gespeicherte Spec gemergt) -> Re-Probe VOR dem Gate (exakt der Cron-Pfad inkl. Load model config = model.monitor_acquisition zur Laufzeit; Jump-Guard prüft die neue Quelle gegen den letzten sauberen Wert — fängt Skalen-/Quellenwechsel). Typ-Wechsel lehnt die fn ab (delete + create). Web-Cadence >= 12h DB-CHECK.' 320 560

    $nodes = @($trig, $resolveDomain, $resolve, $ifFound, $errFound, $ifSpec, $ifWeb, $loadModel, $acquire,
               $shape, $probe, $ifProbeOk, $errProbe, $summary, $reqApproval, $ifApproved,
               $retCancelled, $set, $ifOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve domain' ) ) }
        'Resolve domain'          = @{ main = @( ,@( E 'Resolve trigger' ) ) }
        'Resolve trigger'         = @{ main = @( ,@( E 'Found?' ) ) }
        'Found?'                  = @{ main = @(
            @( E 'Spec changed?' ),
            @( E 'Not found' )
        ) }
        'Spec changed?'           = @{ main = @(
            @( E 'Web probe?' ),
            @( E 'Build Approval Summary' )
        ) }
        'Web probe?'              = @{ main = @(
            @( E 'Load model config' ),
            @( E 'Probe (validate)' )
        ) }
        'Load model config'       = @{ main = @( ,@( E 'Acquire web value' ) ) }
        'Acquire web value'       = @{ main = @( ,@( E 'Shape probe observation' ) ) }
        'Shape probe observation' = @{ main = @( ,@( E 'Probe (validate)' ) ) }
        'Probe (validate)'        = @{ main = @( ,@( E 'Probe ok?' ) ) }
        'Probe ok?'               = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Probe failed' )
        ) }
        'Build Approval Summary'  = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'        = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'               = @{ main = @(
            @( E 'Set trigger (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set trigger (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_set_monitor_trigger' $nodes $conns `
        @{ Category = 'monitoring' }
}
