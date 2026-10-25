#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_create_monitor_trigger (CROSS-AGENT, HITL-Write) -------------
# Legt EINEN Monitor-Trigger an (Tabelle agent.monitor_triggers). Binder: agent.monitor
# (domain vom LLM aus bekanntem Set) + ein Fach-Advisor (domain+package FIX = sein Paket).
# E2E-Sentinel-Switch lebt IM Tool (chat_id startsWith test_e2e -> domain __e2e_monitor__),
# damit EIN Switch alle Binder deckt (der Monitor-Agent liefert domain per $fromAI).
# PROBE VOR DEM GATE: die Beschaffung laeuft einmal exakt wie der Cron (web: Claude-web_search-HTTP
# + Parse; sql/Paket-Methoden: in fn_monitor_probe, sql unter core_ro) + Validierungs-Kaskade — Probe-Fail
# = ToolError VOR dem Gate (nichts geschrieben), Probe-Wert steht in der Approval-Summary
# und wird nach Approve als erste Observation geloggt (+ Drawdown-Ratchet-Seed).
# Phase B: Paket-Methoden (core.monitor_acquisition_methods) nehmen ihre Parameter als EIN Feld acquisition_params
# (JSON-String, geschuetzt geparst); die Bestaetigungszeile (z. B. "Waehrungspaar: EUR/KRW") liefert die validate_fn
# des Pakets ueber die Probe (probe_display), die Methoden-Labels backt build.ps1 aus den Manifesten.
function Build-CreateMonitorTrigger {
    $trig = Build-Trigger @(
        'domain', 'package', 'label', 'trigger_type', 'acquisition_method',
        'acquisition_prompt', 'acquisition_sql', 'acquisition_params',
        'comparator', 'threshold_value', 'drawdown_pct',
        'due_date', 'warn_days_before',
        'expected_unit', 'min_plausible', 'max_plausible', 'max_jump_pct',
        'check_interval', 'action_note'
    )

    # E2E-Sentinel-Switch (ein Switch fuer alle Binder; fn_clear_e2e_data raeumt die Domain)
    $resolveDomain = Build-Set 'Resolve domain' @(180, 0) @(
        ,@('domain', '={{ String($(''Start'').item.json.chat_id || '''').startsWith(''test_e2e'') ? ''__e2e_monitor__'' : ($(''Start'').item.json.domain || ''general'') }}', 'string')
    )

    # create_*-Konvention: deterministischer Dubletten-Backstop VOR dem Gate
    $dupCheck = Build-Pg 'Check duplicate label' @(360, 0) `
        "=SELECT r.hit_count FROM agent.fn_resolve_monitor_trigger((`$1::jsonb)->>'label', (`$1::jsonb)->>'domain', false) AS r;" `
        ([ordered]@{
            label  = '$(''Start'').item.json.label'
            domain = '$(''Resolve domain'').item.json.domain'
        })
    $ifDup = Build-If 'Duplicate?' @(540, 0) '={{ $json.hit_count }}' '1' 'largerEqual' 'number'
    $errDup = Build-ToolError 'Already exists' @(720, -200) `
        '=A trigger with this label already exists in this domain. Use tool_set_monitor_trigger to change it, or pick a different label.'

    # Probe: nur web braucht den HTTP-Abruf; sql/none/Paket-Methoden beschafft fn_monitor_probe selbst.
    # Exklusive Branches (jedes Item geht GENAU einen Weg) -> der Probe-Pg-Node laeuft exakt 1x.
    $paramsExpr = Get-GuardedJsonExpr '$(''Start'').item.json.acquisition_params ? JSON.parse($(''Start'').item.json.acquisition_params) : null'
    $ifWeb = Build-If 'Web probe?' @(720, 0) `
        "={{ `$('Start').item.json.acquisition_method }}" 'web_search' 'equals' 'string'
    $loadModel = New-MonitorModelConfigNode -Pos @(810, -260)
    $acquire = New-MonitorAcquireHttpNode 'Acquire web value' @(900, -120) "`$('Start').item.json.acquisition_prompt"
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = (Get-MonitorShapeJs 'return [{ json: { probe: obs } }];') }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(1080, -120)
        id = (New-Id)
        name = 'Shape probe observation'
    }

    $probe = Build-Pg 'Probe (validate)' @(1260, 0) `
        "=SELECT (r->>'ok')::boolean AND d.err IS NULL AS probe_ok, (r->>'value')::numeric AS probe_value, r->>'unit' AS probe_unit, r->>'as_of' AS probe_as_of, r->>'source_url' AS probe_source, COALESCE(d.err, r->>'reason') AS probe_reason, r->'display' AS probe_display, r::text AS probe_json, d.due::text AS due_resolved FROM agent.fn_monitor_probe(`$1::jsonb) AS r, LATERAL (SELECT x.due, CASE WHEN (`$1::jsonb)->>'trigger_type' = 'date' AND x.due IS NULL THEN 'due_date must be YYYY-MM-DD or relative to today (e.g. +6 months, in 3 weeks)' WHEN x.due < core.fn_today() THEN 'due_date ' || x.due || ' is in the past' END AS err FROM (SELECT CASE WHEN (`$1::jsonb)->>'trigger_type' = 'date' THEN core.fn_resolve_date(NULLIF((`$1::jsonb)->>'due_date', '')) END AS due) x) d;" `
        ([ordered]@{
            trigger_type       = '$(''Start'').item.json.trigger_type'
            due_date           = '$(''Start'').item.json.due_date'
            acquisition_method = '$(''Start'').item.json.acquisition_method'
            acquisition_sql    = '$(''Start'').item.json.acquisition_sql'
            acquisition_params = $paramsExpr
            expected_unit      = '$(''Start'').item.json.expected_unit'
            min_plausible      = '$(''Start'').item.json.min_plausible'
            max_plausible      = '$(''Start'').item.json.max_plausible'
            observation        = '($json.probe || null)'
        })
    $ifProbeOk = Build-If 'Probe ok?' @(1440, 0) '={{ $json.probe_ok }}' 'true' 'equals' 'boolean'
    $errProbe = Build-ToolError 'Probe failed' @(1620, -200) `
        "={{ 'The check BEFORE approval failed - nothing was created. Reason: ' + (`$('Probe (validate)').item.json.probe_reason || 'unknown') + '. Fix it together with the user (acquisition prompt/sql/acquisition_params, unit, bounds or due_date) and retry.' }}"

    # Strukturiertes Summary (Textkatalog; zu viel Logik fuer Einzel-Zeilen -> -LinesExpr). Methoden-Bezeichnung =
    # <pkg>.monitor_method.<methode> ($MonitorMethodPkgJson {methode: paket}, Core-Builtins unter core.*), fehlt sie ->
    # Methodenname. probe_display ist die Bestaetigungszeile der Paket-validate_fn (kind raw): ein tpl-Objekt (Textkatalog
    # Phase C, gerendert in der Sprache des Bestaetigers) oder - aeltere Pakete - ein fertiger String.
    $linesExpr = @'
(() => {
  const s = $('Start').item.json;
  const p = $('Probe (validate)').item.json;
  const PKG = __PKG_METHODS__;
  const m = s.acquisition_method || 'none';
  const methodKey = (['web_search', 'sql', 'none'].includes(m) ? 'core' : (PKG[m] || 'core')) + '.monitor_method.' + m;
  const cut = (x) => { const v = String(x || ''); return v.slice(0, 200) + (v.length > 200 ? '…' : ''); };
  const unit = (u) => (u ? ' ' + u : '');
  const L = [];
  L.push({ label: 'core.label.label', kind: 'text', value: s.label });
  L.push({ label: 'core.label.domain', kind: 'text', value: $('Resolve domain').item.json.domain });
  L.push({ label: 'core.label.type', kind: 'enum', enum: 'core.enum.trigger_type', value: s.trigger_type });
  if (s.trigger_type === 'threshold') L.push({ label: 'core.label.condition', kind: 'tpl', value: 'core.tpl.monitor_threshold',
    params: { op: (s.comparator === 'lte' ? '<=' : '>='), value: s.threshold_value, unit: unit(s.expected_unit) } });
  if (s.trigger_type === 'drawdown') L.push({ label: 'core.label.condition', kind: 'tpl', value: 'core.tpl.monitor_drawdown',
    params: { pct: s.drawdown_pct } });
  if (s.trigger_type === 'date') L.push(Number(s.warn_days_before) > 0
    ? { label: 'core.label.due', kind: 'tpl', value: 'core.tpl.monitor_due_warn',
        params: { date: { kind: 'date', value: p.due_resolved }, days: s.warn_days_before } }
    : { label: 'core.label.due', kind: 'date', value: p.due_resolved });
  L.push({ label: 'core.label.check_interval', kind: 'tpl', value: 'core.tpl.monitor_every', params: { interval: s.check_interval } });
  L.push({ label: 'core.label.source', kind: 'key', value: methodKey, fallback: m });
  if (m === 'web_search') L.push({ label: 'core.label.prompt_start', kind: 'text', value: '"' + cut(s.acquisition_prompt) + '"' });
  if (m === 'sql') L.push({ label: 'core.label.sql_start', kind: 'text', value: cut(s.acquisition_sql) });
  if (p.probe_display) L.push({ kind: 'raw', value: p.probe_display });
  if (s.min_plausible || s.max_plausible) L.push({ label: 'core.label.plausible', kind: 'tpl', value: 'core.tpl.range',
    params: { min: s.min_plausible || '-', max: s.max_plausible || '-' } });
  if (s.max_jump_pct) L.push({ label: 'core.label.jump_guard', kind: 'tpl', value: 'core.tpl.monitor_jump_guard', params: { pct: s.max_jump_pct } });
  if (m !== 'none') {
    const has = p.probe_value !== null && p.probe_value !== undefined;
    L.push(!has ? { label: 'core.label.probe', kind: 'text', value: '' }
      : (p.probe_source
        ? { label: 'core.label.probe', kind: 'tpl', value: (p.probe_as_of ? 'core.tpl.monitor_probe_source_asof' : 'core.tpl.monitor_probe_source'),
            params: { value: p.probe_value, unit: unit(p.probe_unit), source: p.probe_source, asof: p.probe_as_of || '' } }
        : { label: 'core.label.probe', kind: 'text', value: String(p.probe_value) + unit(p.probe_unit) }));
  }
  L.push({ label: 'core.label.action_on_fire', kind: 'text', value: s.action_note });
  L.push({ kind: 'note', value: 'core.note.monitor_full_text' });
  return L;
})()
'@
    $linesExpr = $linesExpr.Replace('__PKG_METHODS__', $MonitorMethodPkgJson).Trim()
    $summary = New-HitlSummary -Pos @(1620, 0) -Title 'core.hitl.create_monitor_trigger' -LinesExpr $linesExpr

    $reqApproval = Build-CallWorkflow 'Request Approval' @(1800, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2160, 200) 'the create_monitor_trigger action'

    $create = Build-Pg 'Create trigger (atomic)' @(2160, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'trigger_id')::int AS trigger_id, r->>'status' AS status, r->>'next_check_at' AS next_check_at, r->>'check_interval' AS check_interval, (r->>'armed_count')::int AS armed_count FROM agent.fn_create_monitor_trigger(`$1::jsonb) AS r;" `
        ([ordered]@{
            domain             = '$(''Resolve domain'').item.json.domain'
            package            = '$(''Start'').item.json.package'
            label              = '$(''Start'').item.json.label'
            trigger_type       = '$(''Start'').item.json.trigger_type'
            acquisition_method = '$(''Start'').item.json.acquisition_method'
            acquisition_prompt = '$(''Start'').item.json.acquisition_prompt'
            acquisition_sql    = '$(''Start'').item.json.acquisition_sql'
            acquisition_params = $paramsExpr
            comparator         = '$(''Start'').item.json.comparator'
            threshold_value    = '$(''Start'').item.json.threshold_value'
            drawdown_pct       = '$(''Start'').item.json.drawdown_pct'
            due_date           = '($(''Probe (validate)'').item.json.due_resolved || $(''Start'').item.json.due_date)'
            warn_days_before   = '$(''Start'').item.json.warn_days_before'
            expected_unit      = '$(''Start'').item.json.expected_unit'
            min_plausible      = '$(''Start'').item.json.min_plausible'
            max_plausible      = '$(''Start'').item.json.max_plausible'
            max_jump_pct       = '$(''Start'').item.json.max_jump_pct'
            check_interval     = '$(''Start'').item.json.check_interval'
            action_note        = '$(''Start'').item.json.action_note'
            probe_observation  = 'JSON.parse($(''Probe (validate)'').item.json.probe_json || ''null'')'
        })

    $ifOk = Build-If 'Write ok?' @(2340, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Create rejected' @(2520, 200) "={{ `$('Create trigger (atomic)').item.json.reason }}"

    $ret = Build-Return @(2520, 0) @(
        ,@('ok','true','boolean')
        ,@('trigger_id', '={{ $json.trigger_id }}', 'number')
        ,@('status', '={{ $json.status }}', 'string')
        ,@('next_check_at', '={{ $json.next_check_at }}', 'string')
        ,@('check_interval', '={{ $json.check_interval }}', 'string')
        ,@('armed_count', '={{ $json.armed_count }}', 'number')
    )

    $stickyOverview = Build-Sticky 'Doc Create Trigger' @(120, -460) `
        'Probe vor Gate + agent.fn_create_monitor_trigger (atomar)' `
        'Fälligkeit (date-Trigger): Probe (validate) löst due_date per core.fn_resolve_date EINMAL auf (YYYY-MM-DD oder relativ wie +6 months); ungültig oder vergangen -> ToolError vor dem Gate; Karte und Write nutzen genau dieses Datum. Cross-agent (Monitor-Agent: domain via LLM, package fix core; Fach-Advisor: domain+package fix = sein Paket). package = Lifecycle-Owner (Purge-Schlüssel, fn_pkg_purge_data räumt WHERE package=<pkg> AND origin=user) — fix per Binding, NIE $fromAI. E2E-Switch IM Tool: chat_id test_e2e -> Sentinel-Domain __e2e_monitor__ (package erbt den Binding-Wert; fn_clear_e2e_data räumt per domain). Ablauf: Dubletten-Backstop (UNIQUE(domain,lower(label)) ist DB-Gesetz) -> PROBE (web: Claude-web_search-HTTP + deterministischer Parse, gleicher Vertrag wie der Cron; sql/Paket-Methoden: fn_monitor_probe beschafft selbst, sql unter SET LOCAL ROLE core_ro, Paket-Methode über ihre Registry-fns aus core.monitor_acquisition_methods — acquisition_params geschützt geparst, die validate_fn des Pakets liefert die Bestätigungszeile) + Validierungs-Kaskade (numerisch/Unit-Echo/Bounds) -> Probe-Fail = ToolError VOR dem Gate -> HITL-Summary MIT Test-Abruf-Wert -> fn_create_monitor_trigger (alle CHECKs als {ok:false} gespiegelt; Probe wird erste Observation + Drawdown-Ratchet-Seed). Web-Cadence >= 12h ist DB-CHECK (Free-Tier-Schutz).' 320 560

    $stickyBranch = Build-Sticky 'Doc Probe-Branch' @(880, -340) `
        'Exklusive Branches statt Merge' `
        'Web probe? routet jedes Item GENAU einen Weg (web: Load model config [model.monitor_acquisition, bei jedem Lauf aus core.config] + HTTP + Parse; sonst direkt) — beide Wege münden in Probe (validate), der dadurch exakt 1x läuft. Kein Merge-Node nötig (im Repo unbewiesen).' 180 360

    $nodes = @($trig, $resolveDomain, $dupCheck, $ifDup, $errDup, $ifWeb, $loadModel, $acquire, $shape,
               $probe, $ifProbeOk, $errProbe, $summary, $reqApproval, $ifApproved,
               $retCancelled, $create, $ifOk, $errWrite, $ret, $stickyOverview, $stickyBranch)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve domain' ) ) }
        'Resolve domain'          = @{ main = @( ,@( E 'Check duplicate label' ) ) }
        'Check duplicate label'   = @{ main = @( ,@( E 'Duplicate?' ) ) }
        'Duplicate?'              = @{ main = @(
            @( E 'Already exists' ),
            @( E 'Web probe?' )
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
            @( E 'Create trigger (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create trigger (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Create rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_create_monitor_trigger' $nodes $conns `
        @{ Category = 'monitoring' }
}
