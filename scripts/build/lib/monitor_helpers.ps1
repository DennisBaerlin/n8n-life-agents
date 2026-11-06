#Requires -Version 5.1
# Gemeinsame Builder-Helper fuer das Trigger-Monitoring (agent.monitor_*):
# Web-Beschaffung per Claude web_search (geteilter Baustein New-AnthropicMessagesNode) mit striktem
# JSON-Vertrag + deterministischem Parse.
# Genutzt von den monitor-Build-Defs in packages/core/build/workflows/ (tools/create_monitor_trigger.ps1,
# tools/set_monitor_trigger.ps1, cron.monitor_check_triggers.ps1) — der Abruf-Pfad ist ueberall IDENTISCH (derselbe
# Vertrag wie im Cron, damit die Probe vor dem Gate exakt das testet, was spaeter laeuft).
# Dot-gesourct von build.ps1 (sieht $RepoRoot + die lib-Helper im Parent-Scope).

# Strikter Antwort-Vertrag der Wert-Beschaffung (EN, build-time Konstante).
$script:MonitorSysText = 'You retrieve exactly ONE metric value via web search. Respond with ONLY a single JSON object, no prose, no markdown fences: {"ok": true|false, "value": number|null, "unit": "unit exactly as requested in the query", "as_of": "date the value refers to (YYYY-MM-DD if known)", "source_url": "best source url", "reason": "only when ok=false"}. Set ok=false with a concrete reason when the value cannot be RELIABLY determined (sources conflict, data is stale or paywalled). Never guess. value is a plain number with dot decimal, no thousands separators, no units inside value.'

# HTTP-Node fuer EINEN Web-Abruf (laeuft per-Item). $PromptExpr ist ein roher
# JS-Ausdruck, der den gespeicherten Retrieval-Prompt WOERTLICH liefert (nie umformuliert).
# Modell = model.monitor_acquisition, zur LAUFZEIT aus dem Knoten 'Load model config' (New-MonitorModelConfigNode,
# muss in jedem Aufrufer-Workflow vor diesem Knoten liegen). JSON per Prompt-Vertrag + Parse,
# bewusst OHNE output_config.format (der Vertrag ist seit v1 prompt-getragen; der Parse unten ist robust).
function New-MonitorAcquireHttpNode {
    param([string]$Name, [int[]]$Pos, [string]$PromptExpr)
    New-AnthropicMessagesNode -Name $Name -Position $Pos -ConfigModelKey 'monitor_acquisition' -System $script:MonitorSysText `
        -ContentJs "String($PromptExpr || '')" -Effort medium -WebSearchMaxUses 3 -TimeoutMs 120000
}

# Der zugehoerige Config-Knoten (identisch in Cron + Create/Set-Tool, damit die Probe vor dem Gate exakt das
# Modell nutzt, das spaeter der Cron nimmt).
function New-MonitorModelConfigNode {
    param([int[]]$Pos)
    New-ModelConfigNode -Position $Pos -Keys @( ,@('core', 'monitor_acquisition') )
}

# Deterministischer Parse des Abruf-Outputs (Stufe 1 der Validierungs-Kaskade):
# Fences strippen, ERSTEN balancierten {...}-Block extrahieren (die Antwort kann Zitat-Text um das JSON
# tragen), value muss finite number sein; jeder Parse-Fehler (auch abgeschnittene Antwort/Ablehnung/
# unfertige Suche via anthropicText) wird {ok:false, reason} -> Fehlerpfad (fail_streak), nie Exception.
# $ResultExprJs: JS-Zeilen, die aus dem geparsten Objekt `obs` das Item bauen
# (z. B. 'return [{ json: { probe: obs } }];' fuer die Tool-Probe).
# -PerItem: fuer Code-Nodes im runOnceForEachItem-Modus — n8n blockt `.first()` dort
# STATISCH (auch im nicht genommenen Ternary-Zweig; real getroffen), daher zwei Varianten.
function Get-MonitorShapeJs {
    param([string]$ResultExprJs, [string]$Prelude = '', [switch]$PerItem)
    $accessor = if ($PerItem) { 'const r = $input.item.json;' } else { 'const r = $input.first().json;' }
    $anthropicJs = Get-AnthropicResultJs
    @"
$Prelude
$anthropicJs
$accessor
const mk = (o) => { const obs = o; $ResultExprJs };
const fail = (m) => mk({ ok: false, reason: String(m).slice(0, 300) });
const res = anthropicText(r);
if (!res.ok) return fail(res.error);
const text = stripFences(res.text);
const start = text.indexOf('{');
if (start < 0) return fail('no JSON object in model output');
let depth = 0, end = -1;
for (let i = start; i < text.length; i++) {
  if (text[i] === '{') depth++;
  else if (text[i] === '}') { depth--; if (depth === 0) { end = i; break; } }
}
if (end < 0) return fail('unbalanced JSON in model output');
let o;
try { o = JSON.parse(text.slice(start, end + 1)); } catch (e) { return fail('unparseable model output'); }
if (o.ok !== true) return mk({ ok: false, reason: String(o.reason || 'model reported cannot_determine').slice(0, 300) });
if (typeof o.value !== 'number' || !isFinite(o.value)) return fail('value is not a finite number');
return mk({ ok: true, value: o.value, unit: String(o.unit || ''), as_of: String(o.as_of || ''), source_url: String(o.source_url || '') });
"@
}
